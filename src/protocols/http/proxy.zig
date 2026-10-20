//! Applies an engine-owned proxy policy to each HTTP client before requests.
//! The proxy endpoint contains no credentials; secret-store integration is a
//! separate platform capability. A custom endpoint never falls back to direct.

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;

pub const Policy = struct {
    mode: @import("../../core/job_store.zig").ProxyMode = .system,
    url: ?[]const u8 = null,
    authentication_required: bool = false,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    proxy: http.Client.Proxy = undefined,
    https_proxy: http.Client.Proxy = undefined,
    host: ?[]u8 = null,
    https_host: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        if (self.host) |host| self.allocator.free(host);
        if (self.https_host) |host| self.allocator.free(host);
    }

    fn reset(self: *State, client: *http.Client) void {
        if (self.host) |host| self.allocator.free(host);
        if (self.https_host) |host| self.allocator.free(host);
        self.host = null;
        self.https_host = null;
        client.http_proxy = null;
        client.https_proxy = null;
    }

    /// Call before a request and keep this state alive until the client has
    /// been deinitialized. `openGet` reapplies it for each redirect hop.
    /// Unsupported custom proxy types fail closed.
    pub fn apply(self: *State, client: *http.Client, policy: Policy, target: std.Uri) !void {
        if (policy.mode == .system) {
            if (comptime builtin.os.tag == .macos) try self.applyMacOSSystem(client, target);
            return;
        }
        if (policy.mode != .custom) return;
        // A saved Keychain credential is not yet available to this headless
        // transport. Never silently make an unauthenticated request when the
        // user configured the proxy as requiring authentication.
        if (policy.authentication_required) return error.ProxyAuthenticationUnavailable;
        const url = policy.url orelse return error.InvalidProxy;
        const uri = std.Uri.parse(url) catch return error.InvalidProxy;
        const path_ok = uri.path.isEmpty() or switch (uri.path) {
            .raw => |path| std.mem.eql(u8, path, "/"),
            .percent_encoded => |path| std.mem.eql(u8, path, "/"),
        };
        if (uri.user != null or uri.password != null or uri.fragment != null or uri.query != null or !path_ok)
            return error.InvalidProxy;
        const protocol = http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedProxyType;
        var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const hostname = std.Io.net.HostName.fromUri(uri, &host_buffer) catch return error.InvalidProxy;
        self.host = try self.allocator.dupe(u8, hostname.bytes);
        self.proxy = .{
            .protocol = protocol,
            .host = .{ .bytes = self.host.? },
            .authorization = null,
            .port = uri.port orelse if (protocol == .tls) 443 else 80,
            .supports_connect = true,
        };
        client.http_proxy = &self.proxy;
        client.https_proxy = &self.proxy;
    }

    fn applyMacOSSystem(self: *State, client: *http.Client, target: std.Uri) !void {
        const config = try systemProxyConfig(self.allocator, client.io);
        if (config.auto_config or config.auto_discovery or config.socks_enabled)
            return error.UnsupportedSystemProxyConfiguration;
        if (bypassesSystemProxy(config, target)) return;
        if (config.http_enabled) {
            if (config.http_host_len == 0 or config.http_port == 0) return error.InvalidSystemProxy;
            self.host = try self.allocator.dupe(u8, config.http_host[0..config.http_host_len]);
            self.proxy = .{
                .protocol = .plain,
                .host = .{ .bytes = self.host.? },
                .authorization = null,
                .port = config.http_port,
                .supports_connect = true,
            };
            client.http_proxy = &self.proxy;
        }
        if (config.https_enabled) {
            if (config.https_host_len == 0 or config.https_port == 0) return error.InvalidSystemProxy;
            self.https_host = try self.allocator.dupe(u8, config.https_host[0..config.https_host_len]);
            self.https_proxy = .{
                .protocol = .plain,
                .host = .{ .bytes = self.https_host.? },
                .authorization = null,
                .port = config.https_port,
                .supports_connect = true,
            };
            client.https_proxy = &self.https_proxy;
        }
    }
};

/// A request and response with stable storage for redirected URI components.
/// The caller may mark `request.connection.?.closing` before deinit when it
/// intentionally abandons a response body.
pub const Opened = struct {
    allocator: std.mem.Allocator,
    request: *http.Client.Request,
    response: http.Client.Response,
    redirect_buffer: []u8,
    uri_storage: ?[]u8 = null,

    pub fn deinit(self: *Opened) void {
        self.request.deinit();
        self.allocator.destroy(self.request);
        self.allocator.free(self.redirect_buffer);
        if (self.uri_storage) |value| self.allocator.free(value);
    }
};

/// Follow at most three redirects, applying proxy policy to each destination.
/// Never downgrade an HTTPS source to HTTP or accept redirect credentials.
/// Request headers must outlive `Opened`.
pub fn openGet(client: *http.Client, state: *State, policy: Policy, initial_uri: std.Uri, options: http.Client.RequestOptions) !Opened {
    const allocator = state.allocator;
    var owned_uri: ?[]u8 = null;
    errdefer if (owned_uri) |value| allocator.free(value);
    var uri = initial_uri;
    for (0..4) |hop| {
        state.reset(client);
        try state.apply(client, policy, uri);
        var request_options = options;
        request_options.redirect_behavior = .unhandled;
        var opened = try openOnce(client, uri, request_options);
        if (opened.response.head.status.class() != .redirect or opened.response.head.status == .not_modified) {
            opened.uri_storage = owned_uri;
            return opened;
        }
        const next = blk: {
            defer opened.deinit();
            // A redirect body is irrelevant and may be arbitrarily large.
            opened.request.connection.?.closing = true;
            opened.request.reader.state = .ready;
            if (hop == 3) return error.TooManyHttpRedirects;
            const location = opened.response.head.location orelse return error.HttpRedirectLocationMissing;
            if (location.len > 8 * 1024) return error.HttpRedirectLocationOversize;
            var resolve_buffer: [16 * 1024]u8 = undefined;
            @memcpy(resolve_buffer[0..location.len], location);
            var available: []u8 = resolve_buffer[0..];
            var redirected = opened.request.uri.resolveInPlace(location.len, &available) catch return error.HttpRedirectLocationInvalid;
            redirected.scheme = if (std.ascii.eqlIgnoreCase(redirected.scheme, "https"))
                "https"
            else if (std.ascii.eqlIgnoreCase(redirected.scheme, "http"))
                "http"
            else
                return error.UnsupportedUriScheme;
            if (std.ascii.eqlIgnoreCase(opened.request.uri.scheme, "https") and std.ascii.eqlIgnoreCase(redirected.scheme, "http"))
                return error.InsecureHttpRedirect;
            if (redirected.user != null or redirected.password != null)
                return error.HttpRedirectCredentials;
            redirected.fragment = null;
            const resolved = try uriString(allocator, redirected);
            break :blk resolved;
        };
        if (owned_uri) |value| allocator.free(value);
        owned_uri = next;
        uri = std.Uri.parse(next) catch return error.HttpRedirectLocationInvalid;
    }
    unreachable;
}

fn openOnce(client: *http.Client, uri: std.Uri, options: http.Client.RequestOptions) !Opened {
    const allocator = client.allocator;
    const request = try allocator.create(http.Client.Request);
    errdefer allocator.destroy(request);
    request.* = try client.request(.GET, uri, options);
    errdefer request.deinit();
    const redirect_buffer = try allocator.alloc(u8, 8 * 1024);
    errdefer allocator.free(redirect_buffer);
    try request.sendBodiless();
    const response = try request.receiveHead(redirect_buffer);
    return .{ .allocator = allocator, .request = request, .response = response, .redirect_buffer = redirect_buffer };
}

fn uriString(allocator: std.mem.Allocator, uri: std.Uri) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try uri.format(&output.writer);
    return allocator.dupe(u8, output.written());
}

const SystemProxyConfig = struct {
    http_enabled: bool = false,
    https_enabled: bool = false,
    socks_enabled: bool = false,
    auto_config: bool = false,
    auto_discovery: bool = false,
    http_host: [256]u8 = @splat(0),
    http_host_len: usize = 0,
    https_host: [256]u8 = @splat(0),
    https_host_len: usize = 0,
    http_port: u16 = 0,
    https_port: u16 = 0,
    exclude_simple_hostnames: bool = false,
    exception_count: usize = 0,
    exceptions: [32][256]u8 = @splat(@splat(0)),
    exception_lengths: [32]usize = @splat(0),
};

const SystemProxyCache = struct {
    mutex: std.Io.Mutex = .init,
    expires_ns: i96 = 0,
    valid: bool = false,
    config: SystemProxyConfig = .{},
};

var system_proxy_cache: SystemProxyCache = .{};

fn systemProxyConfig(allocator: std.mem.Allocator, io: std.Io) !SystemProxyConfig {
    system_proxy_cache.mutex.lockUncancelable(io);
    defer system_proxy_cache.mutex.unlock(io);
    const now = std.Io.Clock.now(.awake, io).nanoseconds;
    if (system_proxy_cache.valid and now < system_proxy_cache.expires_ns)
        return system_proxy_cache.config;
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "/usr/sbin/scutil", "--proxy" },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(1024),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(3000), .clock = .awake } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) return error.SystemProxyUnavailable;
    const config = try parseSystemProxyConfig(result.stdout);
    system_proxy_cache.config = config;
    system_proxy_cache.expires_ns = now + 30 * std.time.ns_per_s;
    system_proxy_cache.valid = true;
    return config;
}

fn parseSystemProxyConfig(output: []const u8) !SystemProxyConfig {
    var config: SystemProxyConfig = .{};
    var reading_exceptions = false;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (reading_exceptions) {
            if (std.mem.eql(u8, line, "}")) {
                reading_exceptions = false;
                continue;
            }
            const entry_separator = std.mem.indexOf(u8, line, " : ") orelse return error.InvalidSystemProxy;
            const value = line[entry_separator + 3 ..];
            var entries = std.mem.splitScalar(u8, value, ',');
            while (entries.next()) |raw_entry| {
                const entry = std.mem.trim(u8, raw_entry, " \t");
                if (config.exception_count == config.exceptions.len) return error.InvalidSystemProxy;
                const index = config.exception_count;
                config.exception_lengths[index] = try copyException(&config.exceptions[index], entry);
                config.exception_count += 1;
            }
            continue;
        }
        const separator = std.mem.indexOf(u8, line, " : ") orelse continue;
        const key = line[0..separator];
        const value = line[separator + 3 ..];
        if (std.mem.eql(u8, key, "ExceptionsList")) {
            if (!std.mem.eql(u8, value, "<array> {")) return error.InvalidSystemProxy;
            reading_exceptions = true;
        } else if (std.mem.eql(u8, key, "ExcludeSimpleHostnames")) {
            config.exclude_simple_hostnames = std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "HTTPEnable")) {
            config.http_enabled = std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "HTTPSEnable")) {
            config.https_enabled = std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "SOCKSEnable")) {
            config.socks_enabled = std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "ProxyAutoConfigEnable")) {
            config.auto_config = std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "ProxyAutoDiscoveryEnable")) {
            config.auto_discovery = std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "HTTPProxy")) {
            config.http_host_len = try copyHost(&config.http_host, value);
        } else if (std.mem.eql(u8, key, "HTTPSProxy")) {
            config.https_host_len = try copyHost(&config.https_host, value);
        } else if (std.mem.eql(u8, key, "HTTPPort")) {
            config.http_port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidSystemProxy;
        } else if (std.mem.eql(u8, key, "HTTPSPort")) {
            config.https_port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidSystemProxy;
        }
    }
    if (reading_exceptions) return error.InvalidSystemProxy;
    return config;
}

fn bypassesSystemProxy(config: SystemProxyConfig, target: std.Uri) bool {
    const uri_host = target.host orelse return false;
    const host = switch (uri_host) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
    if (config.exclude_simple_hostnames and std.mem.indexOfScalar(u8, host, '.') == null and !isIp6Literal(host)) return true;
    for (0..config.exception_count) |index| {
        const pattern = config.exceptions[index][0..config.exception_lengths[index]];
        if (std.mem.indexOfScalar(u8, pattern, '/') != null) {
            if (cidrExceptionMatches(pattern, host)) return true;
        } else if (hostPatternMatches(pattern, host)) return true;
    }
    return false;
}

fn hostPatternMatches(pattern: []const u8, host: []const u8) bool {
    var pattern_index: usize = 0;
    var host_index: usize = 0;
    var last_star: ?usize = null;
    var retry_host: usize = 0;
    while (host_index < host.len) {
        if (pattern_index < pattern.len and std.ascii.toLower(pattern[pattern_index]) == std.ascii.toLower(host[host_index])) {
            pattern_index += 1;
            host_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            last_star = pattern_index;
            pattern_index += 1;
            retry_host = host_index;
        } else if (last_star) |star| {
            retry_host += 1;
            host_index = retry_host;
            pattern_index = star + 1;
        } else return false;
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') : (pattern_index += 1) {}
    return pattern_index == pattern.len;
}

fn copyHost(destination: *[256]u8, value: []const u8) !usize {
    if (value.len == 0 or value.len > destination.len) return error.InvalidSystemProxy;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '/' or byte == '@')
        return error.InvalidSystemProxy;
    @memcpy(destination[0..value.len], value);
    return value.len;
}

fn copyException(destination: *[256]u8, value: []const u8) !usize {
    if (value.len == 0 or value.len > destination.len) return error.InvalidSystemProxy;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '@')
        return error.InvalidSystemProxy;
    if (std.mem.indexOfScalar(u8, value, '/') != null and parseCidr(value) == null)
        return error.InvalidSystemProxy;
    @memcpy(destination[0..value.len], value);
    return value.len;
}

const Cidr = union(enum) {
    ip4: struct { bytes: [4]u8, prefix: u8 },
    ip6: struct { bytes: [16]u8, prefix: u8 },
};

fn parseCidr(pattern: []const u8) ?Cidr {
    const slash = std.mem.indexOfScalar(u8, pattern, '/') orelse return null;
    const network = pattern[0..slash];
    const prefix_text = pattern[slash + 1 ..];
    if (network.len == 0 or prefix_text.len == 0) return null;
    for (prefix_text) |byte| if (!std.ascii.isDigit(byte)) return null;
    const prefix = std.fmt.parseInt(u8, prefix_text, 10) catch return null;
    if (std.mem.indexOfScalar(u8, network, ':') != null) {
        if (prefix > 128) return null;
        const address = std.Io.net.IpAddress.parseIp6(network, 0) catch return null;
        return .{ .ip6 = .{ .bytes = address.ip6.bytes, .prefix = prefix } };
    }
    if (prefix > 32) return null;
    // macOS accepts abbreviated IPv4 networks such as 169.254/16.
    var bytes: [4]u8 = @splat(0);
    var parts = std.mem.splitScalar(u8, network, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (count == bytes.len or part.len == 0) return null;
        for (part) |byte| if (!std.ascii.isDigit(byte)) return null;
        bytes[count] = std.fmt.parseInt(u8, part, 10) catch return null;
        count += 1;
    }
    return .{ .ip4 = .{ .bytes = bytes, .prefix = prefix } };
}

fn isIp6Literal(host: []const u8) bool {
    const bare = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
    _ = std.Io.net.IpAddress.parseIp6(bare, 0) catch return false;
    return true;
}

fn cidrExceptionMatches(pattern: []const u8, host: []const u8) bool {
    const cidr = parseCidr(pattern) orelse return false;
    switch (cidr) {
        .ip4 => |network| {
            const address = std.Io.net.IpAddress.parseIp4(host, 0) catch return false;
            return prefixMatches(4, network.bytes, address.ip4.bytes, network.prefix);
        },
        .ip6 => |network| {
            const bare = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
            const address = std.Io.net.IpAddress.parseIp6(bare, 0) catch return false;
            return prefixMatches(16, network.bytes, address.ip6.bytes, network.prefix);
        },
    }
}

fn prefixMatches(comptime length: usize, network: [length]u8, address: [length]u8, prefix: u8) bool {
    const full_bytes: usize = prefix / 8;
    if (!std.mem.eql(u8, network[0..full_bytes], address[0..full_bytes])) return false;
    const remaining: u8 = prefix % 8;
    if (remaining == 0) return true;
    const mask: u8 = @truncate(@as(u16, 0xff00) >> @intCast(remaining));
    return network[full_bytes] & mask == address[full_bytes] & mask;
}
