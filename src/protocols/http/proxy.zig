//! Applies an engine-owned proxy policy to each HTTP client before requests.
//! The proxy endpoint contains no credentials; secret-store integration is a
//! separate platform capability. A custom endpoint never falls back to direct.

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;

pub const Policy = struct {
    mode: @import("../../core/job_store.zig").ProxyMode = .system,
    url: ?[]const u8 = null,
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

    /// Call before the first request and keep this state alive until the
    /// client has been deinitialized. Unsupported custom proxy types fail
    /// closed, so a download cannot bypass a configured proxy silently.
    pub fn apply(self: *State, client: *http.Client, policy: Policy, target: std.Uri) !void {
        if (policy.mode == .system) {
            if (comptime builtin.os.tag == .macos) try self.applyMacOSSystem(client, target);
            return;
        }
        if (policy.mode != .custom) return;
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
            if (config.exception_count == config.exceptions.len) return error.InvalidSystemProxy;
            const value = line[entry_separator + 3 ..];
            const index = config.exception_count;
            config.exception_lengths[index] = try copyHost(&config.exceptions[index], value);
            config.exception_count += 1;
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
    if (config.exclude_simple_hostnames and std.mem.indexOfScalar(u8, host, '.') == null) return true;
    for (0..config.exception_count) |index| {
        const pattern = config.exceptions[index][0..config.exception_lengths[index]];
        if (hostPatternMatches(pattern, host)) return true;
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
