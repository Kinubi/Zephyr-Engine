// Zephyr Engine - Unified Error System
// Provides consistent error handling across the engine with context and recovery mechanisms

const std = @import("std");

/// Core engine error set
/// All engine errors should be part of this set for consistent handling
pub const EngineError = error{
    // Initialization errors
    InitializationFailed,
    AlreadyInitialized,
    NotInitialized,
    
    // Resource errors
    ResourceNotFound,
    ResourceLoadFailed,
    ResourceAlreadyExists,
    InvalidResourceHandle,
    
    // Graphics errors
    DeviceCreationFailed,
    SwapchainCreationFailed,
    PipelineCreationFailed,
    ShaderCompilationFailed,
    CommandBufferAllocationFailed,
    
    // Memory errors
    OutOfMemory,
    AllocationFailed,
    MemoryBudgetExceeded,
    InvalidMemoryType,
    
    // Vulkan errors
    VulkanError,
    DeviceLost,
    SurfaceLost,
    OutOfDate,
    
    // State errors
    InvalidState,
    OperationNotSupported,
    Timeout,
    
    // File system errors
    FileNotFound,
    FileReadFailed,
    FileWriteFailed,
    
    // Threading errors
    ThreadPoolShutdown,
    WorkItemFailed,
};

/// Error context for debugging and logging
pub const ErrorContext = struct {
    error_code: EngineError,
    message: []const u8,
    file: []const u8,
    line: u32,
    function: []const u8,
    
    /// Create error context with location information
    pub fn init(
        err: EngineError,
        message: []const u8,
        src: std.builtin.SourceLocation,
    ) ErrorContext {
        return .{
            .error_code = err,
            .message = message,
            .file = src.file,
            .line = src.line,
            .function = src.fn_name,
        };
    }
    
    /// Format error for logging
    pub fn format(
        self: ErrorContext,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("[{s}] {s} ({s}:{d} in {s})", .{
            @errorName(self.error_code),
            self.message,
            self.file,
            self.line,
            self.function,
        });
    }
};

/// Error handler callback type
pub const ErrorHandler = *const fn (ctx: ErrorContext) void;

/// Global error handler (can be set by application)
var global_error_handler: ?ErrorHandler = null;

/// Set a global error handler for all engine errors
pub fn setErrorHandler(handler: ErrorHandler) void {
    global_error_handler = handler;
}

/// Report an error with context
pub fn reportError(ctx: ErrorContext) void {
    if (global_error_handler) |handler| {
        handler(ctx);
    }
}

/// Helper macro for creating errors with context
pub inline fn makeError(
    comptime err: EngineError,
    comptime message: []const u8,
) EngineError {
    const ctx = ErrorContext.init(err, message, @src());
    reportError(ctx);
    return err;
}

/// Convert Vulkan result to engine error
pub fn fromVulkanResult(result: anytype) EngineError!void {
    switch (@intFromEnum(result)) {
        @intFromEnum(std.os.linux.VK.SUCCESS) => return,
        @intFromEnum(std.os.linux.VK.ERROR_OUT_OF_HOST_MEMORY),
        @intFromEnum(std.os.linux.VK.ERROR_OUT_OF_DEVICE_MEMORY) => return EngineError.OutOfMemory,
        @intFromEnum(std.os.linux.VK.ERROR_DEVICE_LOST) => return EngineError.DeviceLost,
        @intFromEnum(std.os.linux.VK.ERROR_SURFACE_LOST_KHR) => return EngineError.SurfaceLost,
        @intFromEnum(std.os.linux.VK.ERROR_OUT_OF_DATE_KHR) => return EngineError.OutOfDate,
        else => return EngineError.VulkanError,
    }
}

/// Error recovery strategy
pub const RecoveryStrategy = enum {
    /// Retry the operation
    retry,
    /// Use a fallback method
    fallback,
    /// Skip the operation and continue
    skip,
    /// Abort execution
    abort,
};

/// Error recovery context
pub const Recovery = struct {
    strategy: RecoveryStrategy,
    retry_count: u32 = 0,
    max_retries: u32 = 3,
    
    pub fn init(strategy: RecoveryStrategy) Recovery {
        return .{ .strategy = strategy };
    }
    
    pub fn shouldRetry(self: *Recovery) bool {
        if (self.strategy != .retry) return false;
        if (self.retry_count >= self.max_retries) return false;
        self.retry_count += 1;
        return true;
    }
};

// Tests
test "ErrorContext creation" {
    const ctx = ErrorContext.init(
        EngineError.InitializationFailed,
        "Test error message",
        @src(),
    );
    try std.testing.expectEqual(EngineError.InitializationFailed, ctx.error_code);
    try std.testing.expectEqualStrings("Test error message", ctx.message);
}

test "Recovery retry logic" {
    var recovery = Recovery.init(.retry);
    recovery.max_retries = 2;
    
    try std.testing.expect(recovery.shouldRetry()); // 1st retry
    try std.testing.expect(recovery.shouldRetry()); // 2nd retry
    try std.testing.expect(!recovery.shouldRetry()); // exceeds max
}

test "Recovery skip strategy" {
    var recovery = Recovery.init(.skip);
    try std.testing.expect(!recovery.shouldRetry());
}
