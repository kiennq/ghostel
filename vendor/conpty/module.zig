const std = @import("std");
const emacs = @import("emacs");
const Conpty = @import("conpty.zig");

const c = emacs.c;
const Registry = std.AutoHashMap(usize, *Conpty.State);

export const plugin_is_GPL_compatible: c_int = 1;

var registry = Registry.init(std.heap.c_allocator);

fn termKey(env: emacs.Env, value: emacs.Value) ?usize {
    const raw_ptr = env.raw.get_user_ptr.?(env.raw, value) orelse return null;
    return @intFromPtr(raw_ptr);
}

fn put(term_key: usize, state: *Conpty.State) !void {
    try registry.put(term_key, state);
}

fn get(term_key: usize) ?*Conpty.State {
    return registry.get(term_key);
}

fn remove(term_key: usize) ?*Conpty.State {
    const entry = registry.fetchRemove(term_key) orelse return null;
    return entry.value;
}

fn fnConptyInit(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const key = termKey(env, args[0]) orelse {
        env.signalError("conpty: invalid terminal handle");
        return env.nil();
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var command_stack: [512]u8 = undefined;
    var cwd_stack: [512]u8 = undefined;
    const command = env.extractString(args[2], &command_stack) orelse blk: {
        break :blk env.extractStringAlloc(args[2], allocator);
    };
    const cwd = env.extractString(args[5], &cwd_stack) orelse blk: {
        break :blk env.extractStringAlloc(args[5], allocator);
    };

    if (command == null or cwd == null) {
        env.signalError("conpty: invalid arguments");
        return env.nil();
    }

    if (remove(key)) |existing| {
        Conpty.deinit(existing);
    }

    const state = Conpty.init(
        env,
        args[1],
        command.?,
        @intCast(env.extractInteger(args[3])),
        @intCast(env.extractInteger(args[4])),
        cwd.?,
        args[6],
        allocator,
    ) catch {
        env.signalError("conpty: failed to initialize backend");
        return env.nil();
    };
    errdefer Conpty.deinit(state);

    put(key, state) catch {
        env.signalError("conpty: failed to register backend state");
        return env.nil();
    };

    return env.t();
}

fn fnConptyReadPending(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const key = termKey(env, args[0]) orelse return env.nil();
    const state = get(key) orelse return env.nil();
    return Conpty.readPending(env, state);
}

fn fnConptyWrite(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const key = termKey(env, args[0]) orelse return env.nil();
    const state = get(key) orelse return env.nil();

    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stack_buf: [65536]u8 = undefined;
    const data = env.extractString(args[1], &stack_buf) orelse blk: {
        break :blk env.extractStringAlloc(args[1], allocator);
    };
    if (data == null) return env.nil();

    Conpty.write(state, data.?) catch {
        env.signalError("conpty: failed to write to backend");
        return env.nil();
    };
    return env.t();
}

fn fnConptyResize(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const key = termKey(env, args[0]) orelse return env.nil();
    const state = get(key) orelse return env.nil();
    return if (Conpty.resize(
        state,
        @intCast(env.extractInteger(args[1])),
        @intCast(env.extractInteger(args[2])),
    )) env.t() else env.nil();
}

fn fnConptyIsAlive(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const key = termKey(env, args[0]) orelse return env.nil();
    const state = get(key) orelse return env.nil();
    return if (Conpty.isAlive(state)) env.t() else env.nil();
}

fn fnConptyKill(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const key = termKey(env, args[0]) orelse return env.nil();
    const state = remove(key) orelse return env.nil();
    const killed = Conpty.kill(state);
    Conpty.deinit(state);
    return if (killed) env.t() else env.nil();
}

export fn emacs_module_init(runtime: *c.struct_emacs_runtime) callconv(.c) c_int {
    if (runtime.size < @sizeOf(c.struct_emacs_runtime)) return 1;

    const raw_env = runtime.get_environment.?(runtime);
    const env = emacs.Env.init(raw_env);

    env.bindFunction("conpty--init", 7, 7, &fnConptyInit, "Start a Windows ConPTY backend.\n\n(conpty--init TERM PROCESS COMMAND ROWS COLS CWD ENV)");
    env.bindFunction("conpty--is-alive", 1, 1, &fnConptyIsAlive, "Return t if the Windows ConPTY child is alive.\n\n(conpty--is-alive TERM)");
    env.bindFunction("conpty--kill", 1, 1, &fnConptyKill, "Terminate the Windows ConPTY child.\n\n(conpty--kill TERM)");
    env.bindFunction("conpty--read-pending", 1, 1, &fnConptyReadPending, "Read pending Windows ConPTY output.\n\n(conpty--read-pending TERM)");
    env.bindFunction("conpty--resize", 3, 3, &fnConptyResize, "Resize the Windows ConPTY backend.\n\n(conpty--resize TERM ROWS COLS)");
    env.bindFunction("conpty--write", 2, 2, &fnConptyWrite, "Write raw bytes to the Windows ConPTY backend.\n\n(conpty--write TERM DATA)");

    emacs.initSymbols(env);
    env.provide("conpty-module");
    return 0;
}
