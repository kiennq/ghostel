const std = @import("std");

var threaded: std.Io.Threaded = .init_single_threaded;

pub fn get() std.Io {
    return threaded.io();
}
