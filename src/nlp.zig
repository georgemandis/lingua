const std = @import("std");
const builtin = @import("builtin");

const platform = switch (builtin.os.tag) {
    .macos => @import("platform/macos.zig"),
    else => @compileError("Unsupported platform. Currently supported: macOS."),
};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const LanguageResult = struct {
    language: []const u8,
    confidence: f64,
};

pub const TokenResult = struct {
    token: []const u8,
    range_start: usize,
    range_length: usize,
};

pub const SentimentResult = struct {
    text: []const u8,
    score: f64,
};

pub const PosTag = struct {
    token: []const u8,
    tag: []const u8,
};

pub const EntityTag = struct {
    token: []const u8,
    tag: []const u8, // PersonalName, PlaceName, OrganizationName
    range_start: usize,
    range_length: usize,
};

pub const LemmaResult = struct {
    token: []const u8,
    lemma: []const u8,
};

pub const DetectedEntity = struct {
    entity_type: []const u8, // phone, email, address, date, url, link, transit
    value: []const u8,
    range_start: usize,
    range_length: usize,
};

pub const TokenUnit = enum {
    word,
    sentence,
    paragraph,
};

pub const NlpError = error{
    FrameworkUnavailable,
    DetectionFailed,
    OutOfMemory,
    UnsupportedPlatform,
};

// ---------------------------------------------------------------------------
// Platform dispatch functions
// ---------------------------------------------------------------------------

pub fn detectLanguage(allocator: std.mem.Allocator, text: []const u8, top_n: usize) NlpError![]LanguageResult {
    return platform.detectLanguage(allocator, text, top_n);
}

pub fn tokenize(allocator: std.mem.Allocator, text: []const u8, unit: TokenUnit) NlpError![]TokenResult {
    return platform.tokenize(allocator, text, unit);
}

pub fn analyzeSentiment(allocator: std.mem.Allocator, text: []const u8, per_sentence: bool) NlpError![]SentimentResult {
    return platform.analyzeSentiment(allocator, text, per_sentence);
}

pub fn tagPartsOfSpeech(allocator: std.mem.Allocator, text: []const u8) NlpError![]PosTag {
    return platform.tagPartsOfSpeech(allocator, text);
}

pub fn extractNamedEntities(allocator: std.mem.Allocator, text: []const u8) NlpError![]EntityTag {
    return platform.extractNamedEntities(allocator, text);
}

pub fn detectEntities(allocator: std.mem.Allocator, text: []const u8) NlpError![]DetectedEntity {
    return platform.detectEntities(allocator, text);
}

pub fn lemmatize(allocator: std.mem.Allocator, text: []const u8) NlpError![]LemmaResult {
    return platform.lemmatize(allocator, text);
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------

pub fn freeLanguageResults(allocator: std.mem.Allocator, results: []LanguageResult) void {
    for (results) |r| allocator.free(r.language);
    allocator.free(results);
}

pub fn freeTokenResults(allocator: std.mem.Allocator, results: []TokenResult) void {
    for (results) |r| allocator.free(r.token);
    allocator.free(results);
}

pub fn freeSentimentResults(allocator: std.mem.Allocator, results: []SentimentResult) void {
    for (results) |r| allocator.free(r.text);
    allocator.free(results);
}

pub fn freePosTags(allocator: std.mem.Allocator, results: []PosTag) void {
    for (results) |r| {
        allocator.free(r.token);
        allocator.free(r.tag);
    }
    allocator.free(results);
}

pub fn freeEntityTags(allocator: std.mem.Allocator, results: []EntityTag) void {
    for (results) |r| {
        allocator.free(r.token);
        allocator.free(r.tag);
    }
    allocator.free(results);
}

pub fn freeDetectedEntities(allocator: std.mem.Allocator, results: []DetectedEntity) void {
    for (results) |r| {
        allocator.free(r.entity_type);
        allocator.free(r.value);
    }
    allocator.free(results);
}

pub fn freeLemmaResults(allocator: std.mem.Allocator, results: []LemmaResult) void {
    for (results) |r| {
        allocator.free(r.token);
        allocator.free(r.lemma);
    }
    allocator.free(results);
}
