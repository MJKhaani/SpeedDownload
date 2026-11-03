//! Applies an engine-owned proxy policy to each HTTP client before requests.
//! The proxy endpoint contains no credentials. On macOS, authenticated custom
//! proxies read the user's Keychain item; Windows uses Credential Manager.
//! A custom endpoint never falls back to direct.

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;
const connection_budget = @import("connection_budget.zig");

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
    authorization: ?[]u8 = null,
    budget: ?*connection_budget.Budget = null,
    control: ?connection_budget.ControlCallback = null,
    control_context: ?*anyopaque = null,
    budget_deadline_ns: ?i96 = null,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn initWithBudget(allocator: std.mem.Allocator, budget: ?*connection_budget.Budget, control: ?connection_budget.ControlCallback, context: ?*anyopaque) State {
        return .{ .allocator = allocator, .budget = budget, .control = control, .control_context = context };
    }

    pub fn deinit(self: *State) void {
        if (self.host) |host| self.allocator.free(host);
        if (self.https_host) |host| self.allocator.free(host);
        self.clearAuthorization();
    }

    fn clearAuthorization(self: *State) void {
        if (self.authorization) |value| {
            @memset(value, 0);
            self.allocator.free(value);
            self.authorization = null;
        }
    }

    fn reset(self: *State, client: *http.Client) void {
        if (self.host) |host| self.allocator.free(host);
        if (self.https_host) |host| self.allocator.free(host);
        self.host = null;
        self.https_host = null;
        self.clearAuthorization();
        client.http_proxy = null;
        client.https_proxy = null;
    }

    /// Call before a request and keep this state alive until the client has
    /// been deinitialized. `openGet` reapplies it for each redirect hop.
    /// Unsupported custom proxy types fail closed.
    pub fn apply(self: *State, client: *http.Client, policy: Policy, target: std.Uri) !void {
        if (policy.mode == .system) {
            if (comptime builtin.os.tag == .macos) try self.applyMacOSSystem(client, target);
            if (comptime builtin.os.tag == .linux) try self.applyLinuxSystem(client, target);
            if (comptime builtin.os.tag == .windows) try self.applyWindowsSystem(client, target);
            return;
        }
        if (policy.mode != .custom) return;
        const url = policy.url orelse return error.InvalidProxy;
        try self.applyEndpoint(client, url);
        if (policy.authentication_required) {
            // Zig 0.17 does not attach Proxy-Authorization to CONNECT. Ordinary
            // HTTP forwarding does attach it; never attempt HTTPS unauthenticated.
            if (std.ascii.eqlIgnoreCase(target.scheme, "https")) return error.AuthenticatedHttpsProxyUnsupported;
            self.authorization = if (comptime builtin.os.tag == .macos)
                try keychainProxyAuthorization(self.allocator)
            else if (comptime builtin.os.tag == .windows)
                try windowsProxyAuthorization(self.allocator, url)
            else
                return error.ProxyAuthenticationUnavailable;
            self.proxy.authorization = self.authorization.?;
            self.proxy.supports_connect = false;
        }
    }

    fn applyEndpoint(self: *State, client: *http.Client, url: []const u8) !void {
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

    fn applyLinuxSystem(self: *State, client: *http.Client, target: std.Uri) !void {
        if (linuxNoProxyMatches(target)) return;
        const is_https = std.ascii.eqlIgnoreCase(target.scheme, "https");
        const endpoint = if (is_https)
            linuxEnvFirst(&.{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" })
        else
            linuxEnvFirst(&.{ "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY" });
        const value = endpoint orelse return;
        if (std.mem.indexOf(u8, value, "://") != null) {
            try self.applyEndpoint(client, value);
        } else {
            const url = try std.fmt.allocPrint(self.allocator, "http://{s}", .{value});
            defer self.allocator.free(url);
            try self.applyEndpoint(client, url);
        }
    }

    fn applyWindowsSystem(self: *State, client: *http.Client, target: std.Uri) !void {
        if (comptime builtin.os.tag != .windows) return error.UnsupportedSystemProxyConfiguration;
        var config: WindowsProxyConfig = std.mem.zeroes(WindowsProxyConfig);
        defer if (config.auto_url) |value| { _ = GlobalFree(@ptrCast(value)); };
        defer if (config.proxy) |value| { _ = GlobalFree(@ptrCast(value)); };
        defer if (config.bypass) |value| { _ = GlobalFree(@ptrCast(value)); };
        if (WinHttpGetIEProxyConfigForCurrentUser(&config) == 0) {
            if (GetLastError() == 2) return; // No per-user proxy configuration.
            return error.InvalidSystemProxy;
        }

        var automatic: WindowsProxyInfo = std.mem.zeroes(WindowsProxyInfo);
        defer if (automatic.proxy) |value| { _ = GlobalFree(@ptrCast(value)); };
        defer if (automatic.bypass) |value| { _ = GlobalFree(@ptrCast(value)); };
        var use_automatic = false;
        if (config.auto_detect != 0 or config.auto_url != null) {
            const session = WinHttpOpen(null, 1, null, null, 0) orelse return error.InvalidSystemProxy;
            defer _ = WinHttpCloseHandle(session);
            const raw_url = try uriString(self.allocator, target);
            defer self.allocator.free(raw_url);
            const wide_url = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, raw_url);
            defer self.allocator.free(wide_url);
            const options: WindowsAutoProxyOptions = .{
                .flags = (if (config.auto_detect != 0) @as(u32, 1) else 0) | (if (config.auto_url != null) @as(u32, 2) else 0),
                .auto_detect_flags = if (config.auto_detect != 0) 3 else 0,
                .auto_config_url = config.auto_url,
                .reserved = null, .reserved_number = 0, .auto_logon = 0,
            };
            if (WinHttpGetProxyForUrl(session, wide_url, &options, &automatic) != 0) {
                use_automatic = true;
            } else if (config.auto_url != null or GetLastError() != 12180) {
                return error.UnsupportedSystemProxyConfiguration;
            }
        }
        const proxy_value = if (use_automatic) automatic.proxy else config.proxy;
        const bypass_value = if (use_automatic) automatic.bypass else config.bypass;
        if (use_automatic and automatic.access_type == 1) return; // WinHTTP resolved DIRECT.
        if (use_automatic and automatic.access_type != 3) return error.UnsupportedSystemProxyConfiguration;
        if (proxy_value == null) {
            if (use_automatic and automatic.access_type != 1) return error.InvalidSystemProxy;
            return;
        }
        if (bypass_value) |wide| {
            const bypass = try std.unicode.utf16LeToUtf8Alloc(self.allocator, std.mem.span(wide));
            defer self.allocator.free(bypass);
            if (try windowsProxyBypasses(bypass, target)) return;
        }
        const proxy_list = try std.unicode.utf16LeToUtf8Alloc(self.allocator, std.mem.span(proxy_value.?));
        defer self.allocator.free(proxy_list);
        const endpoint = try windowsProxyForScheme(proxy_list, target.scheme) orelse return;
        const url = if (std.mem.indexOf(u8, endpoint, "://") != null)
            try self.allocator.dupe(u8, endpoint)
        else
            try std.fmt.allocPrint(self.allocator, "http://{s}", .{endpoint});
        defer self.allocator.free(url);
        try self.applyEndpoint(client, url);
    }

    fn applyMacOSSystem(self: *State, client: *http.Client, target: std.Uri) !void {
        const config = try systemProxyConfig(self.allocator, client.io);
        if (bypassesSystemProxy(config, target)) return;
        if (config.auto_config or config.auto_discovery)
            return error.UnsupportedSystemProxyConfiguration;
        const target_is_https = std.ascii.eqlIgnoreCase(target.scheme, "https");
        if (config.socks_enabled and !(if (target_is_https) config.https_enabled else config.http_enabled))
            return error.UnsupportedSystemProxyConfiguration;
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

fn keychainProxyAuthorization(allocator: std.mem.Allocator) ![]u8 {
    if (comptime builtin.os.tag != .macos) return error.ProxyAuthenticationUnavailable;
    const service = "com.mjkhaani.SpeedDownload.proxy";
    const account = "manual-proxy";
    var length: u32 = 0;
    var data: ?*anyopaque = null;
    const status = SecKeychainFindGenericPassword(null, service.len, service.ptr, account.len, account.ptr, &length, &data, null);
    if (status != 0 or data == null) return error.ProxyCredentialsUnavailable;
    defer _ = SecKeychainItemFreeContent(null, data);
    if (length == 0 or length > 4096) return error.ProxyCredentialsUnavailable;
    const bytes: [*]const u8 = @ptrCast(data.?);
    const secret = bytes[0..length];
    return proxyAuthorizationFromSecret(allocator, secret);
}

fn proxyAuthorizationFromSecret(allocator: std.mem.Allocator, secret: []const u8) ![]u8 {
    if (secret.len == 0 or secret.len > 4096) return error.ProxyCredentialsUnavailable;
    const separator = std.mem.indexOfScalar(u8, secret, '\n') orelse return error.ProxyCredentialsUnavailable;
    if (std.mem.indexOfScalar(u8, secret[0..separator], ':') != null or
        std.mem.indexOfScalar(u8, secret, '\r') != null or std.mem.indexOfScalar(u8, secret, 0) != null)
        return error.ProxyCredentialsUnavailable;
    const encoded_len = std.base64.standard.Encoder.calcSize(secret.len);
    const authorization = try allocator.alloc(u8, "Basic ".len + encoded_len);
    errdefer allocator.free(authorization);
    @memcpy(authorization[0.."Basic ".len], "Basic ");
    var credentials: [4096]u8 = undefined;
    defer @memset(credentials[0..secret.len], 0);
    @memcpy(credentials[0..separator], secret[0..separator]);
    credentials[separator] = ':';
    @memcpy(credentials[separator + 1 .. secret.len], secret[separator + 1 ..]);
    _ = std.base64.standard.Encoder.encode(authorization["Basic ".len..], credentials[0..secret.len]);
    return authorization;
}

test "proxy credentials are encoded without accepting invalid separators" {
    const allocator = std.testing.allocator;
    const authorization = try proxyAuthorizationFromSecret(allocator, "user\npassword");
    defer allocator.free(authorization);
    try std.testing.expectEqualStrings("Basic dXNlcjpwYXNzd29yZA==", authorization);
    try std.testing.expectError(error.ProxyCredentialsUnavailable, proxyAuthorizationFromSecret(allocator, "user:bad\npassword"));
    try std.testing.expectError(error.ProxyCredentialsUnavailable, proxyAuthorizationFromSecret(allocator, "missing-separator"));
}

const WindowsCredential = extern struct {
    flags: u32,
    credential_type: u32,
    target_name: ?[*:0]u16,
    comment: ?[*:0]u16,
    last_written: extern struct { low: u32, high: u32 },
    blob_size: u32,
    blob: ?[*]u8,
    persist: u32,
    attribute_count: u32,
    attributes: ?*anyopaque,
    target_alias: ?[*:0]u16,
    user_name: ?[*:0]u16,
};
const WindowsProxyConfig = extern struct {
    auto_detect: i32,
    auto_url: ?[*:0]u16,
    proxy: ?[*:0]u16,
    bypass: ?[*:0]u16,
};
const WindowsProxyInfo = extern struct { access_type: u32, proxy: ?[*:0]u16, bypass: ?[*:0]u16 };
const WindowsAutoProxyOptions = extern struct {
    flags: u32,
    auto_detect_flags: u32,
    auto_config_url: ?[*:0]u16,
    reserved: ?*anyopaque,
    reserved_number: u32,
    auto_logon: i32,
};
extern "winhttp" fn WinHttpGetIEProxyConfigForCurrentUser(*WindowsProxyConfig) callconv(.winapi) i32;
extern "winhttp" fn WinHttpOpen(?[*:0]const u16, u32, ?[*:0]const u16, ?[*:0]const u16, u32) callconv(.winapi) ?*anyopaque;
extern "winhttp" fn WinHttpGetProxyForUrl(*anyopaque, [*:0]const u16, *const WindowsAutoProxyOptions, *WindowsProxyInfo) callconv(.winapi) i32;
extern "winhttp" fn WinHttpCloseHandle(*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GlobalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

fn windowsProxyForScheme(list: []const u8, scheme: []const u8) !?[]const u8 {
    var entries = std.mem.splitScalar(u8, list, ';');
    var saw_scheme = false;
    while (entries.next()) |raw| {
        var entry = std.mem.trim(u8, raw, " \t\r\n");
        if (entry.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(entry, "DIRECT")) return null;
        if (std.mem.indexOfScalar(u8, entry, '=')) |equal| {
            saw_scheme = true;
            const name = std.mem.trim(u8, entry[0..equal], " \t");
            if (!std.ascii.eqlIgnoreCase(name, "http") and !std.ascii.eqlIgnoreCase(name, "https"))
                return error.UnsupportedSystemProxyConfiguration;
            if (!std.ascii.eqlIgnoreCase(name, scheme)) continue;
            entry = std.mem.trim(u8, entry[equal + 1 ..], " \t");
        } else if (entry.len > 6 and std.ascii.eqlIgnoreCase(entry[0..6], "PROXY ")) {
            entry = std.mem.trim(u8, entry[6..], " \t");
        }
        if (entry.len == 0 or std.mem.indexOfAny(u8, entry, " \t\r\n") != null)
            return error.UnsupportedSystemProxyConfiguration;
        return entry;
    }
    if (saw_scheme) return null;
    return error.InvalidSystemProxy;
}

fn windowsProxyBypasses(list: []const u8, target: std.Uri) !bool {
    const part = target.host orelse return error.InvalidSystemProxy;
    const host = switch (part) { .raw => |value| value, .percent_encoded => |value| value };
    const port = target.port orelse if (std.ascii.eqlIgnoreCase(target.scheme, "https")) @as(u16, 443) else 80;
    var entries = std.mem.tokenizeAny(u8, list, ";,");
    while (entries.next()) |raw| {
        var pattern = std.mem.trim(u8, raw, " \t\r\n");
        if (pattern.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(pattern, "<local>")) {
            if (std.mem.indexOfScalar(u8, host, '.') == null and !isIp6Literal(host)) return true;
            continue;
        }
        if (std.mem.indexOfAny(u8, pattern, "<>?@") != null or std.mem.indexOf(u8, pattern, "://") != null)
            return error.UnsupportedSystemProxyConfiguration;
        if (std.mem.lastIndexOfScalar(u8, pattern, ':')) |colon| {
            if (std.mem.indexOfScalar(u8, pattern[0..colon], ':') == null) {
                const required = std.fmt.parseInt(u16, pattern[colon + 1 ..], 10) catch return error.UnsupportedSystemProxyConfiguration;
                if (required != port) continue;
                pattern = pattern[0..colon];
            }
        }
        if (std.mem.indexOfScalar(u8, pattern, '/') != null) {
            if (parseCidr(pattern) == null) return error.UnsupportedSystemProxyConfiguration;
            if (cidrExceptionMatches(pattern, host)) return true;
        } else if (hostPatternMatches(pattern, host)) return true;
    }
    return false;
}

test "Windows system proxy selection and bypass rules" {
    try std.testing.expectEqualStrings("secure:8443", (try windowsProxyForScheme("http=plain:8080;https=secure:8443", "https")).?);
    try std.testing.expect((try windowsProxyForScheme("http=plain:8080", "https")) == null);
    try std.testing.expectEqualStrings("proxy:8080", (try windowsProxyForScheme("PROXY proxy:8080;DIRECT", "http")).?);
    try std.testing.expectError(error.UnsupportedSystemProxyConfiguration, windowsProxyForScheme("socks=proxy:1080", "https"));
    const target = try std.Uri.parse("https://a.example.test/file");
    try std.testing.expect(try windowsProxyBypasses("<local>;*.example.test", target));
    try std.testing.expect(!(try windowsProxyBypasses("*.example.test:80", target)));
    try std.testing.expectError(error.UnsupportedSystemProxyConfiguration, windowsProxyBypasses("<unknown>", target));
}
extern "advapi32" fn CredReadW([*:0]const u16, u32, u32, *?*WindowsCredential) callconv(.winapi) i32;
extern "advapi32" fn CredFree(?*anyopaque) callconv(.winapi) void;

fn windowsProxyAuthorization(allocator: std.mem.Allocator, endpoint: []const u8) ![]u8 {
    if (comptime builtin.os.tag != .windows) return error.ProxyAuthenticationUnavailable;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(endpoint, &digest, .{});
    const target = try std.fmt.allocPrint(allocator, "SpeedDownload.ManualProxy.{s}", .{std.fmt.bytesToHex(digest, .lower)});
    defer allocator.free(target);
    const target_wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, target);
    defer allocator.free(target_wide);
    var credential: ?*WindowsCredential = null;
    if (CredReadW(target_wide, 1, 0, &credential) == 0 or credential == null)
        return error.ProxyCredentialsUnavailable;
    defer CredFree(credential);
    const value = credential.?;
    if (value.blob_size == 0 or value.blob_size > 4096 or value.blob == null) return error.ProxyCredentialsUnavailable;
    const secret = value.blob.?[0..value.blob_size];
    defer @memset(secret, 0);
    return proxyAuthorizationFromSecret(allocator, secret);
}

extern fn SecKeychainFindGenericPassword(?*anyopaque, u32, [*]const u8, u32, [*]const u8, *u32, *?*anyopaque, ?*?*anyopaque) c_int;
extern fn SecKeychainItemFreeContent(?*anyopaque, ?*anyopaque) c_int;

fn linuxEnvFirst(comptime names: []const [:0]const u8) ?[]const u8 {
    if (comptime builtin.os.tag != .linux) return null;
    inline for (names) |name| {
        if (std.c.getenv(name)) |value| {
            const bytes = std.mem.span(value);
            if (bytes.len != 0) return bytes;
        }
    }
    return null;
}

fn linuxNoProxyMatches(target: std.Uri) bool {
    if (comptime builtin.os.tag != .linux) return false;
    const list = linuxEnvFirst(&.{ "no_proxy", "NO_PROXY" }) orelse return false;
    const component = target.host orelse return false;
    const host = switch (component) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
    const port = target.port orelse if (std.ascii.eqlIgnoreCase(target.scheme, "https")) @as(u16, 443) else 80;
    var entries = std.mem.splitScalar(u8, list, ',');
    while (entries.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t");
        if (std.mem.eql(u8, entry, "*")) return true;
        if (entry.len == 0) continue;
        var pattern = entry;
        if (std.mem.lastIndexOfScalar(u8, entry, ':')) |colon| {
            // A port qualifier is only recognized on DNS names and IPv4 hosts.
            if (std.mem.indexOfScalar(u8, entry[0..colon], ':') == null) {
                const required_port = std.fmt.parseInt(u16, entry[colon + 1 ..], 10) catch continue;
                if (required_port != port) continue;
                pattern = entry[0..colon];
            }
        }
        const domain = std.mem.trimStart(u8, pattern, ".");
        if (domain.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(host, domain)) return true;
        if (host.len > domain.len and host[host.len - domain.len - 1] == '.' and
            std.ascii.eqlIgnoreCase(host[host.len - domain.len ..], domain)) return true;
    }
    return false;
}

/// A request and response with stable storage for redirected URI components.
/// The caller may mark `request.connection.?.closing` before deinit when it
/// intentionally abandons a response body.
pub const Opened = struct {
    allocator: std.mem.Allocator,
    request: *http.Client.Request,
    response: http.Client.Response,
    redirect_buffer: []u8,
    uri_storage: ?[]u8 = null,
    permit: ?connection_budget.Budget.Permit = null,

    pub fn deinit(self: *Opened) void {
        self.request.deinit();
        if (self.permit) |*permit| permit.release();
        self.allocator.destroy(self.request);
        self.allocator.free(self.redirect_buffer);
        if (self.uri_storage) |value| self.allocator.free(value);
    }
};

/// Read a body chunk while queued transfers remain responsive to control
/// changes. A canceled read is joined before the response can be destroyed.
pub fn readControlled(io: std.Io, reader: *std.Io.Reader, buffer: []u8, control: ?connection_budget.ControlCallback, context: ?*anyopaque) anyerror!usize {
    if (control == null or context == null) return reader.readSliceShort(buffer);
    try control.?(context.?);
    if (reader.seek < reader.end) {
        const ready = @min(buffer.len, reader.end - reader.seek);
        return reader.readSliceShort(buffer[0..ready]);
    }
    var completed: std.Io.Event = .unset;
    var future = std.Io.concurrent(io, readControlledTask, .{ reader, buffer, &completed, io }) catch
        return reader.readSliceShort(buffer);
    while (true) {
        completed.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            else => {
                _ = future.cancel(io) catch {};
                return err;
            },
        };
        control.?(context.?) catch |err| {
            _ = future.cancel(io) catch {};
            return err;
        };
        if (completed.isSet()) return future.await(io);
    }
}

fn readControlledTask(reader: *std.Io.Reader, buffer: []u8, completed: *std.Io.Event, io: std.Io) std.Io.Reader.ShortError!usize {
    defer completed.set(io);
    return reader.readSliceShort(buffer);
}

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
        var permit: ?connection_budget.Budget.Permit = if (state.budget) |budget|
            try budget.acquireUntil(client.io, uri, state.control, state.control_context, state.budget_deadline_ns)
        else
            null;
        errdefer if (permit) |*held| held.release();
        try state.apply(client, policy, uri);
        var request_options = options;
        request_options.redirect_behavior = .unhandled;
        var opened = try openOnce(client, uri, request_options);
        opened.permit = permit;
        permit = null;
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
