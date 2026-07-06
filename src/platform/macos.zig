const std = @import("std");
const objc = @import("../objc.zig");
const nlp = @import("../nlp.zig");

// ---------------------------------------------------------------------------
// Language Detection (NLLanguageRecognizer)
// ---------------------------------------------------------------------------

pub fn detectLanguage(allocator: std.mem.Allocator, text: []const u8, top_n: usize) nlp.NlpError![]nlp.LanguageResult {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    const NLLanguageRecognizer = objc.getClass("NLLanguageRecognizer") orelse
        return nlp.NlpError.FrameworkUnavailable;

    const recognizer = objc.msgSend(objc.id, NLLanguageRecognizer, objc.sel("alloc"), .{});
    const recognizer_init = objc.msgSend(objc.id, recognizer, objc.sel("init"), .{});

    // Create NSString from text
    const ns_text = createNSStringFromSlice(text) orelse return nlp.NlpError.DetectionFailed;

    // Process the text
    objc.msgSend(void, recognizer_init, objc.sel("processString:"), .{ns_text});

    // Get top N language hypotheses
    const hypotheses = objc.msgSend(objc.id, recognizer_init, objc.sel("languageHypothesesWithMaximum:"), .{@as(objc.NSUInteger, top_n)});

    // Get all keys from the NSDictionary
    const keys = objc.msgSend(objc.id, hypotheses, objc.sel("allKeys"), .{});
    const count = objc.nsArrayCount(keys);

    if (count == 0) {
        // Fallback: try dominant language
        const dominant = objc.msgSend(?objc.id, recognizer_init, objc.sel("dominantLanguage"), .{});
        if (dominant) |lang| {
            const lang_str = objc.fromNSString(lang) orelse return nlp.NlpError.DetectionFailed;
            var results = allocator.alloc(nlp.LanguageResult, 1) catch return nlp.NlpError.OutOfMemory;
            results[0] = .{
                .language = allocator.dupe(u8, std.mem.sliceTo(lang_str, 0)) catch return nlp.NlpError.OutOfMemory,
                .confidence = 1.0,
            };
            return results;
        }
        return nlp.NlpError.DetectionFailed;
    }

    // Collect results and sort by confidence descending
    var results = allocator.alloc(nlp.LanguageResult, count) catch return nlp.NlpError.OutOfMemory;
    var valid_count: usize = 0;

    for (0..count) |i| {
        const key = objc.nsArrayObjectAtIndex(keys, i);
        const value = objc.msgSend(objc.id, hypotheses, objc.sel("objectForKey:"), .{key});

        const lang_cstr = objc.fromNSString(key) orelse continue;
        const lang_slice = std.mem.sliceTo(lang_cstr, 0);

        // Get double value from NSNumber
        const confidence = objc.msgSend(f64, value, objc.sel("doubleValue"), .{});

        results[valid_count] = .{
            .language = allocator.dupe(u8, lang_slice) catch return nlp.NlpError.OutOfMemory,
            .confidence = confidence,
        };
        valid_count += 1;
    }

    const final_results = allocator.realloc(results, valid_count) catch results[0..valid_count];

    // Sort by confidence descending
    std.mem.sort(nlp.LanguageResult, final_results, {}, struct {
        fn lessThan(_: void, a: nlp.LanguageResult, b: nlp.LanguageResult) bool {
            return a.confidence > b.confidence;
        }
    }.lessThan);

    return final_results;
}

// ---------------------------------------------------------------------------
// Tokenization (NLTokenizer)
// ---------------------------------------------------------------------------

pub fn tokenize(allocator: std.mem.Allocator, text: []const u8, unit: nlp.TokenUnit) nlp.NlpError![]nlp.TokenResult {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    const NLTokenizer = objc.getClass("NLTokenizer") orelse
        return nlp.NlpError.FrameworkUnavailable;

    // NLTokenUnit: word=0, sentence=1, paragraph=2
    const token_unit: objc.NSInteger = switch (unit) {
        .word => 0,
        .sentence => 1,
        .paragraph => 2,
    };

    const tokenizer = objc.msgSend(objc.id, NLTokenizer, objc.sel("alloc"), .{});
    const tokenizer_init = objc.msgSend(objc.id, tokenizer, objc.sel("initWithUnit:"), .{token_unit});

    const ns_text = createNSStringFromSlice(text) orelse return nlp.NlpError.DetectionFailed;
    objc.msgSend(void, tokenizer_init, objc.sel("setString:"), .{ns_text});

    // Enumerate tokens by collecting ranges
    const text_length = objc.nsStringLength(ns_text);
    const full_range = objc.NSRange{ .location = 0, .length = text_length };

    // Use tokensForRange: which returns an NSArray of NSValue(NSRange)
    const tokens_array = objc.msgSend(objc.id, tokenizer_init, objc.sel("tokensForRange:"), .{full_range});
    const count = objc.nsArrayCount(tokens_array);

    if (count == 0) {
        const empty = allocator.alloc(nlp.TokenResult, 0) catch return nlp.NlpError.OutOfMemory;
        return empty;
    }

    var results = allocator.alloc(nlp.TokenResult, count) catch return nlp.NlpError.OutOfMemory;
    var valid_count: usize = 0;

    for (0..count) |i| {
        const range_value = objc.nsArrayObjectAtIndex(tokens_array, i);
        const range = objc.msgSend(objc.NSRange, range_value, objc.sel("rangeValue"), .{});

        // Extract substring for this token
        const substring = objc.msgSend(objc.id, ns_text, objc.sel("substringWithRange:"), .{range});
        const cstr = objc.fromNSString(substring) orelse continue;
        const slice = std.mem.sliceTo(cstr, 0);

        results[valid_count] = .{
            .token = allocator.dupe(u8, slice) catch return nlp.NlpError.OutOfMemory,
            .range_start = range.location,
            .range_length = range.length,
        };
        valid_count += 1;
    }

    return allocator.realloc(results, valid_count) catch results[0..valid_count];
}

// ---------------------------------------------------------------------------
// Sentiment Analysis (NLTagger with .sentimentScore)
// ---------------------------------------------------------------------------

pub fn analyzeSentiment(allocator: std.mem.Allocator, text: []const u8, per_sentence: bool) nlp.NlpError![]nlp.SentimentResult {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    if (per_sentence) {
        // Tokenize into sentences first, then score each
        const sentences = try tokenize(allocator, text, .sentence);
        defer {
            for (sentences) |s| allocator.free(s.token);
            allocator.free(sentences);
        }

        var results = allocator.alloc(nlp.SentimentResult, sentences.len) catch return nlp.NlpError.OutOfMemory;
        for (sentences, 0..) |sentence, i| {
            const score = sentimentScore(sentence.token);
            results[i] = .{
                .text = allocator.dupe(u8, sentence.token) catch return nlp.NlpError.OutOfMemory,
                .score = score,
            };
        }
        return results;
    }

    // Whole-text sentiment
    const score = sentimentScore(text);
    var results = allocator.alloc(nlp.SentimentResult, 1) catch return nlp.NlpError.OutOfMemory;
    results[0] = .{
        .text = allocator.dupe(u8, text) catch return nlp.NlpError.OutOfMemory,
        .score = score,
    };
    return results;
}

fn sentimentScore(text: []const u8) f64 {
    const NLTagger = objc.getClass("NLTagger") orelse return 0.0;

    // Create tag schemes array with sentimentScore
    const scheme = objc.nsString("Sentiment");
    const NSArray = objc.getClass("NSArray") orelse return 0.0;
    const schemes = objc.msgSend(objc.id, NSArray, objc.sel("arrayWithObject:"), .{scheme});

    const tagger = objc.msgSend(objc.id, NLTagger, objc.sel("alloc"), .{});
    const tagger_init = objc.msgSend(objc.id, tagger, objc.sel("initWithTagSchemes:"), .{schemes});

    const ns_text = createNSStringFromSlice(text) orelse return 0.0;
    objc.msgSend(void, tagger_init, objc.sel("setString:"), .{ns_text});

    // Get tag for the full range
    const text_length = objc.nsStringLength(ns_text);
    const full_range = objc.NSRange{ .location = 0, .length = text_length };

    const tag = objc.msgSend(?objc.id, tagger_init, objc.sel("tagAtIndex:unit:scheme:tokenRange:"), .{
        @as(objc.NSUInteger, 0),
        @as(objc.NSInteger, 2), // NLTokenUnit.paragraph = 2
        scheme,
        &full_range,
    });

    if (tag) |t| {
        const score_str = objc.fromNSString(t) orelse return 0.0;
        const score_slice = std.mem.sliceTo(score_str, 0);
        return std.fmt.parseFloat(f64, score_slice) catch 0.0;
    }

    return 0.0;
}

// ---------------------------------------------------------------------------
// Part-of-Speech Tagging (NLTagger with .lexicalClass)
// ---------------------------------------------------------------------------

pub fn tagPartsOfSpeech(allocator: std.mem.Allocator, text: []const u8) nlp.NlpError![]nlp.PosTag {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    const NLTagger = objc.getClass("NLTagger") orelse
        return nlp.NlpError.FrameworkUnavailable;

    const scheme = objc.nsString("LexicalClass");
    const NSArray = objc.getClass("NSArray") orelse return nlp.NlpError.FrameworkUnavailable;
    const schemes = objc.msgSend(objc.id, NSArray, objc.sel("arrayWithObject:"), .{scheme});

    const tagger = objc.msgSend(objc.id, NLTagger, objc.sel("alloc"), .{});
    const tagger_init = objc.msgSend(objc.id, tagger, objc.sel("initWithTagSchemes:"), .{schemes});

    const ns_text = createNSStringFromSlice(text) orelse return nlp.NlpError.DetectionFailed;
    objc.msgSend(void, tagger_init, objc.sel("setString:"), .{ns_text});

    // First tokenize to get word boundaries, then tag each
    const tokens = try tokenize(allocator, text, .word);
    defer {
        for (tokens) |t| allocator.free(t.token);
        allocator.free(tokens);
    }

    var results = allocator.alloc(nlp.PosTag, tokens.len) catch return nlp.NlpError.OutOfMemory;
    var valid_count: usize = 0;

    for (tokens) |token| {
        var token_range = objc.NSRange{ .location = token.range_start, .length = token.range_length };
        const tag = objc.msgSend(?objc.id, tagger_init, objc.sel("tagAtIndex:unit:scheme:tokenRange:"), .{
            @as(objc.NSUInteger, token.range_start),
            @as(objc.NSInteger, 0), // NLTokenUnit.word = 0
            scheme,
            &token_range,
        });

        const tag_name = if (tag) |t| blk: {
            const cstr = objc.fromNSString(t) orelse break :blk "Unknown";
            break :blk std.mem.sliceTo(cstr, 0);
        } else "Unknown";

        results[valid_count] = .{
            .token = allocator.dupe(u8, token.token) catch return nlp.NlpError.OutOfMemory,
            .tag = allocator.dupe(u8, tag_name) catch return nlp.NlpError.OutOfMemory,
        };
        valid_count += 1;
    }

    return allocator.realloc(results, valid_count) catch results[0..valid_count];
}

// ---------------------------------------------------------------------------
// Named Entity Recognition (NLTagger with .nameType)
// ---------------------------------------------------------------------------

pub fn extractNamedEntities(allocator: std.mem.Allocator, text: []const u8) nlp.NlpError![]nlp.EntityTag {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    const NLTagger = objc.getClass("NLTagger") orelse
        return nlp.NlpError.FrameworkUnavailable;

    const scheme = objc.nsString("NameType");
    const NSArray = objc.getClass("NSArray") orelse return nlp.NlpError.FrameworkUnavailable;
    const schemes = objc.msgSend(objc.id, NSArray, objc.sel("arrayWithObject:"), .{scheme});

    const tagger = objc.msgSend(objc.id, NLTagger, objc.sel("alloc"), .{});
    const tagger_init = objc.msgSend(objc.id, tagger, objc.sel("initWithTagSchemes:"), .{schemes});

    const ns_text = createNSStringFromSlice(text) orelse return nlp.NlpError.DetectionFailed;
    objc.msgSend(void, tagger_init, objc.sel("setString:"), .{ns_text});

    // Tokenize and check each token for named entity tags
    const tokens = try tokenize(allocator, text, .word);
    defer {
        for (tokens) |t| allocator.free(t.token);
        allocator.free(tokens);
    }

    var results: std.ArrayList(nlp.EntityTag) = .empty;
    defer results.deinit(allocator);

    for (tokens) |token| {
        var token_range = objc.NSRange{ .location = token.range_start, .length = token.range_length };
        const tag = objc.msgSend(?objc.id, tagger_init, objc.sel("tagAtIndex:unit:scheme:tokenRange:"), .{
            @as(objc.NSUInteger, token.range_start),
            @as(objc.NSInteger, 0),
            scheme,
            &token_range,
        });

        if (tag) |t| {
            const tag_cstr = objc.fromNSString(t) orelse continue;
            const tag_name = std.mem.sliceTo(tag_cstr, 0);

            // Filter: only include actual entity tags
            if (std.mem.eql(u8, tag_name, "OtherWord")) continue;
            if (std.mem.eql(u8, tag_name, "Other")) continue;
            if (std.mem.eql(u8, tag_name, "Whitespace")) continue;
            if (std.mem.eql(u8, tag_name, "Punctuation")) continue;
            if (std.mem.eql(u8, tag_name, "SentenceTerminator")) continue;
            if (std.mem.eql(u8, tag_name, "ParagraphBreak")) continue;
            if (std.mem.eql(u8, tag_name, "WordJoiner")) continue;
            if (std.mem.eql(u8, tag_name, "Dash")) continue;
            if (tag_name.len == 0) continue;

            results.append(allocator, .{
                .token = allocator.dupe(u8, token.token) catch return nlp.NlpError.OutOfMemory,
                .tag = allocator.dupe(u8, tag_name) catch return nlp.NlpError.OutOfMemory,
                .range_start = token.range_start,
                .range_length = token.range_length,
            }) catch return nlp.NlpError.OutOfMemory;
        }
    }

    return results.toOwnedSlice(allocator) catch return nlp.NlpError.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Lemmatization (NLTagger with .lemma)
// ---------------------------------------------------------------------------

pub fn lemmatize(allocator: std.mem.Allocator, text: []const u8) nlp.NlpError![]nlp.LemmaResult {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    const NLTagger = objc.getClass("NLTagger") orelse
        return nlp.NlpError.FrameworkUnavailable;

    const scheme = objc.nsString("Lemma");
    const NSArray = objc.getClass("NSArray") orelse return nlp.NlpError.FrameworkUnavailable;
    const schemes = objc.msgSend(objc.id, NSArray, objc.sel("arrayWithObject:"), .{scheme});

    const tagger = objc.msgSend(objc.id, NLTagger, objc.sel("alloc"), .{});
    const tagger_init = objc.msgSend(objc.id, tagger, objc.sel("initWithTagSchemes:"), .{schemes});

    const ns_text = createNSStringFromSlice(text) orelse return nlp.NlpError.DetectionFailed;
    objc.msgSend(void, tagger_init, objc.sel("setString:"), .{ns_text});

    const tokens = try tokenize(allocator, text, .word);
    defer {
        for (tokens) |t| allocator.free(t.token);
        allocator.free(tokens);
    }

    var results = allocator.alloc(nlp.LemmaResult, tokens.len) catch return nlp.NlpError.OutOfMemory;
    var valid_count: usize = 0;

    for (tokens) |token| {
        var token_range = objc.NSRange{ .location = token.range_start, .length = token.range_length };
        const tag = objc.msgSend(?objc.id, tagger_init, objc.sel("tagAtIndex:unit:scheme:tokenRange:"), .{
            @as(objc.NSUInteger, token.range_start),
            @as(objc.NSInteger, 0), // NLTokenUnit.word = 0
            scheme,
            &token_range,
        });

        const lemma = if (tag) |t| blk: {
            const cstr = objc.fromNSString(t) orelse break :blk token.token;
            const slice = std.mem.sliceTo(cstr, 0);
            if (slice.len == 0) break :blk token.token;
            break :blk slice;
        } else token.token;

        results[valid_count] = .{
            .token = allocator.dupe(u8, token.token) catch return nlp.NlpError.OutOfMemory,
            .lemma = allocator.dupe(u8, lemma) catch return nlp.NlpError.OutOfMemory,
        };
        valid_count += 1;
    }

    return allocator.realloc(results, valid_count) catch results[0..valid_count];
}

// ---------------------------------------------------------------------------
// Data Detection (NSDataDetector)
// ---------------------------------------------------------------------------

pub fn detectEntities(allocator: std.mem.Allocator, text: []const u8) nlp.NlpError![]nlp.DetectedEntity {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    const NSDataDetector = objc.getClass("NSDataDetector") orelse
        return nlp.NlpError.FrameworkUnavailable;

    // NSTextCheckingType bitmask values (from Swift):
    // Date = 8, Address = 16, Link = 32, PhoneNumber = 2048, TransitInformation = 4096
    const checking_types: u64 = 8 | 16 | 32 | 2048 | 4096;

    // dataDetectorWithTypes:error:
    var err: ?objc.id = null;
    const detector = objc.msgSend(?objc.id, NSDataDetector, objc.sel("dataDetectorWithTypes:error:"), .{
        checking_types,
        &err,
    }) orelse return nlp.NlpError.DetectionFailed;

    const ns_text = createNSStringFromSlice(text) orelse return nlp.NlpError.DetectionFailed;
    const text_length = objc.nsStringLength(ns_text);
    const full_range = objc.NSRange{ .location = 0, .length = text_length };

    // matchesInString:options:range:
    const matches = objc.msgSend(objc.id, detector, objc.sel("matchesInString:options:range:"), .{
        ns_text,
        @as(objc.NSUInteger, 0),
        full_range,
    });

    const match_count = objc.nsArrayCount(matches);
    if (match_count == 0) {
        return allocator.alloc(nlp.DetectedEntity, 0) catch return nlp.NlpError.OutOfMemory;
    }

    var results: std.ArrayList(nlp.DetectedEntity) = .empty;
    defer results.deinit(allocator);

    for (0..match_count) |i| {
        const match = objc.nsArrayObjectAtIndex(matches, i);

        // Get result type (NSTextCheckingType)
        const result_type = objc.msgSend(u64, match, objc.sel("resultType"), .{});
        const range = objc.msgSend(objc.NSRange, match, objc.sel("range"), .{});

        // Extract the matched substring
        const substring = objc.msgSend(objc.id, ns_text, objc.sel("substringWithRange:"), .{range});
        const value_cstr = objc.fromNSString(substring) orelse continue;
        const value_slice = std.mem.sliceTo(value_cstr, 0);

        const type_name: []const u8 = switch (result_type) {
            8 => "date",
            16 => "address",
            32 => blk: {
                // Check if it's an email (mailto:) or regular link
                const url_obj = objc.msgSend(?objc.id, match, objc.sel("URL"), .{});
                if (url_obj) |url| {
                    const url_scheme = objc.msgSend(?objc.id, url, objc.sel("scheme"), .{});
                    if (url_scheme) |s| {
                        const scheme_cstr = objc.fromNSString(s) orelse break :blk "url";
                        const scheme_slice = std.mem.sliceTo(scheme_cstr, 0);
                        if (std.mem.eql(u8, scheme_slice, "mailto")) break :blk "email";
                    }
                }
                break :blk "url";
            },
            2048 => "phone",
            4096 => "transit",
            else => "other",
        };

        results.append(allocator, .{
            .entity_type = allocator.dupe(u8, type_name) catch return nlp.NlpError.OutOfMemory,
            .value = allocator.dupe(u8, value_slice) catch return nlp.NlpError.OutOfMemory,
            .range_start = range.location,
            .range_length = range.length,
        }) catch return nlp.NlpError.OutOfMemory;
    }

    return results.toOwnedSlice(allocator) catch return nlp.NlpError.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Spelling & Grammar (NSSpellChecker / AppKit)
// ---------------------------------------------------------------------------

fn sharedSpellChecker() ?objc.id {
    const NSSpellChecker = objc.getClass("NSSpellChecker") orelse return null;
    return objc.msgSend(?objc.id, NSSpellChecker, objc.sel("sharedSpellChecker"), .{});
}

fn uniqueSpellDocumentTag() objc.NSInteger {
    const NSSpellChecker = objc.getClass("NSSpellChecker") orelse return 0;
    return objc.msgSend(objc.NSInteger, NSSpellChecker, objc.sel("uniqueSpellDocumentTag"), .{});
}

/// Resolve the language to check against: explicit --lang wins, otherwise
/// auto-detect via NLLanguageRecognizer. Returns an owned slice (caller
/// frees) or null if detection fails (callers then let NSSpellChecker use
/// its own default).
fn resolveLanguage(allocator: std.mem.Allocator, text: []const u8, lang: ?[]const u8) ?[]const u8 {
    if (lang) |l| return allocator.dupe(u8, l) catch null;
    const detected = detectLanguage(allocator, text, 1) catch return null;
    defer nlp.freeLanguageResults(allocator, detected);
    if (detected.len == 0) return null;
    return allocator.dupe(u8, detected[0].language) catch null;
}

pub fn checkSpelling(allocator: std.mem.Allocator, text: []const u8, lang: ?[]const u8) nlp.NlpError![]nlp.SpellingIssue {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    const checker = sharedSpellChecker() orelse return nlp.NlpError.FrameworkUnavailable;
    const tag = uniqueSpellDocumentTag();

    const resolved_lang = resolveLanguage(allocator, text, lang);
    defer if (resolved_lang) |l| allocator.free(l);

    var ns_lang: ?objc.id = null;
    if (resolved_lang) |l| {
        ns_lang = createNSStringFromSlice(l);
        if (ns_lang) |nl| {
            const accepted = objc.msgSend(bool, checker, objc.sel("setLanguage:"), .{nl});
            if (!accepted) {
                // Unsupported dictionary: return no issues rather than
                // flagging every word against the wrong language.
                return allocator.alloc(nlp.SpellingIssue, 0) catch return nlp.NlpError.OutOfMemory;
            }
        }
    }

    const ns_text = createNSStringFromSlice(text) orelse return nlp.NlpError.DetectionFailed;
    const text_length = objc.nsStringLength(ns_text);

    var results: std.ArrayList(nlp.SpellingIssue) = .empty;
    defer results.deinit(allocator);

    var offset: objc.NSUInteger = 0;
    while (offset < text_length) {
        const range = objc.msgSend(objc.NSRange, checker, objc.sel("checkSpellingOfString:startingAt:"), .{
            ns_text,
            @as(objc.NSInteger, @intCast(offset)),
        });
        // checkSpellingOfString:startingAt: is a "find next" primitive built
        // for interactive UI: once it runs past the end of the string it
        // wraps around and returns a match near the start again instead of
        // NSNotFound. Treat a returned location before our scan offset as
        // wraparound and stop, or this loop never terminates.
        if (range.location == objc.NSNotFound or range.length == 0 or range.location < offset) break;

        const substring = objc.msgSend(objc.id, ns_text, objc.sel("substringWithRange:"), .{range});
        const word_cstr = objc.fromNSString(substring) orelse break;
        const word_slice = std.mem.sliceTo(word_cstr, 0);

        var guess_list: std.ArrayList([]const u8) = .empty;
        defer guess_list.deinit(allocator);
        const guess_array = objc.msgSend(?objc.id, checker, objc.sel("guessesForWordRange:inString:language:inSpellDocumentWithTag:"), .{
            range,
            ns_text,
            ns_lang,
            tag,
        });
        if (guess_array) |ga| {
            const gcount = objc.nsArrayCount(ga);
            for (0..gcount) |gi| {
                const g = objc.nsArrayObjectAtIndex(ga, gi);
                const g_cstr = objc.fromNSString(g) orelse continue;
                const g_dup = allocator.dupe(u8, std.mem.sliceTo(g_cstr, 0)) catch return nlp.NlpError.OutOfMemory;
                guess_list.append(allocator, g_dup) catch return nlp.NlpError.OutOfMemory;
            }
        }

        results.append(allocator, .{
            .word = allocator.dupe(u8, word_slice) catch return nlp.NlpError.OutOfMemory,
            .guesses = guess_list.toOwnedSlice(allocator) catch return nlp.NlpError.OutOfMemory,
            .range_start = range.location,
            .range_length = range.length,
        }) catch return nlp.NlpError.OutOfMemory;

        offset = range.location + range.length;
    }

    return results.toOwnedSlice(allocator) catch return nlp.NlpError.OutOfMemory;
}

pub fn checkGrammar(allocator: std.mem.Allocator, text: []const u8, lang: ?[]const u8) nlp.NlpError![]nlp.GrammarIssue {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    const checker = sharedSpellChecker() orelse return nlp.NlpError.FrameworkUnavailable;
    const tag = uniqueSpellDocumentTag();

    const resolved_lang = resolveLanguage(allocator, text, lang);
    defer if (resolved_lang) |l| allocator.free(l);
    const ns_lang: ?objc.id = if (resolved_lang) |l| createNSStringFromSlice(l) else null;

    const ns_text = createNSStringFromSlice(text) orelse return nlp.NlpError.DetectionFailed;
    const text_length = objc.nsStringLength(ns_text);

    var results: std.ArrayList(nlp.GrammarIssue) = .empty;
    defer results.deinit(allocator);

    var offset: objc.NSUInteger = 0;
    while (offset < text_length) {
        var details: ?objc.id = null;
        // Returns the range of the next sentence containing an error;
        // an unsupported language simply never finds one (NSNotFound).
        const sentence_range = objc.msgSend(objc.NSRange, checker, objc.sel("checkGrammarOfString:startingAt:language:wrap:inSpellDocumentWithTag:details:"), .{
            ns_text,
            @as(objc.NSInteger, @intCast(offset)),
            ns_lang,
            false,
            tag,
            &details,
        });
        // Even with wrap=false this API can behave like the spell-check
        // "find next" primitive: guard against a returned location before
        // our scan offset the same way checkSpelling does, or this loop
        // never terminates.
        if (sentence_range.location == objc.NSNotFound or sentence_range.length == 0 or sentence_range.location < offset) break;

        if (details) |details_array| {
            const dcount = objc.nsArrayCount(details_array);
            for (0..dcount) |di| {
                const detail = objc.nsArrayObjectAtIndex(details_array, di);

                const desc_obj = objc.msgSend(?objc.id, detail, objc.sel("objectForKey:"), .{objc.nsString("NSGrammarUserDescription")});
                const description = if (desc_obj) |d| blk: {
                    const cstr = objc.fromNSString(d) orelse break :blk "";
                    break :blk std.mem.sliceTo(cstr, 0);
                } else "";

                // NSGrammarRange is relative to the sentence, not the document.
                const range_obj = objc.msgSend(?objc.id, detail, objc.sel("objectForKey:"), .{objc.nsString("NSGrammarRange")});
                const rel_range = if (range_obj) |rv|
                    objc.msgSend(objc.NSRange, rv, objc.sel("rangeValue"), .{})
                else
                    objc.NSRange{ .location = 0, .length = sentence_range.length };

                const abs_range = objc.NSRange{
                    .location = sentence_range.location + rel_range.location,
                    .length = rel_range.length,
                };
                const substring = objc.msgSend(objc.id, ns_text, objc.sel("substringWithRange:"), .{abs_range});
                const value_cstr = objc.fromNSString(substring) orelse continue;
                const value_slice = std.mem.sliceTo(value_cstr, 0);

                var correction_list: std.ArrayList([]const u8) = .empty;
                defer correction_list.deinit(allocator);
                const corr_obj = objc.msgSend(?objc.id, detail, objc.sel("objectForKey:"), .{objc.nsString("NSGrammarCorrections")});
                if (corr_obj) |ca| {
                    const ccount = objc.nsArrayCount(ca);
                    for (0..ccount) |ci| {
                        const c = objc.nsArrayObjectAtIndex(ca, ci);
                        const c_cstr = objc.fromNSString(c) orelse continue;
                        const c_dup = allocator.dupe(u8, std.mem.sliceTo(c_cstr, 0)) catch return nlp.NlpError.OutOfMemory;
                        correction_list.append(allocator, c_dup) catch return nlp.NlpError.OutOfMemory;
                    }
                }

                results.append(allocator, .{
                    .value = allocator.dupe(u8, value_slice) catch return nlp.NlpError.OutOfMemory,
                    .description = allocator.dupe(u8, description) catch return nlp.NlpError.OutOfMemory,
                    .corrections = correction_list.toOwnedSlice(allocator) catch return nlp.NlpError.OutOfMemory,
                    .range_start = abs_range.location,
                    .range_length = abs_range.length,
                    .sentence_start = sentence_range.location,
                    .sentence_length = sentence_range.length,
                }) catch return nlp.NlpError.OutOfMemory;
            }
        }

        offset = sentence_range.location + sentence_range.length;
    }

    return results.toOwnedSlice(allocator) catch return nlp.NlpError.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn createNSStringFromSlice(text: []const u8) ?objc.id {
    const NSString = objc.getClass("NSString") orelse return null;
    const alloc_str = objc.msgSend(objc.id, NSString, objc.sel("alloc"), .{});
    return objc.msgSend(?objc.id, alloc_str, objc.sel("initWithBytes:length:encoding:"), .{
        text.ptr,
        @as(objc.NSUInteger, text.len),
        @as(objc.NSUInteger, 4), // NSUTF8StringEncoding = 4
    });
}
