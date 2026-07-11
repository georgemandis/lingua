// Style analysis: passive voice, adverb density, sentence length.
// Rule logic is pure (operates on pre-tagged tokens) so it unit-tests
// without macOS framework calls; analyze() composes the nlp module.
const std = @import("std");
const nlp = @import("nlp");

pub const Rule = enum { passive, adverbs, sentence_length };

pub fn ruleName(rule: Rule) []const u8 {
    return switch (rule) {
        .passive => "passive",
        .adverbs => "adverbs",
        .sentence_length => "sentence-length",
    };
}

pub const StyleIssue = struct {
    rule: Rule,
    value: []const u8,
    description: []const u8,
    range_start: usize,
    range_length: usize,
};

pub const Options = struct {
    max_words: usize = 30,
    max_adverbs: usize = 3,
};

pub const TaggedToken = struct {
    token: []const u8,
    tag: []const u8,
    lemma: []const u8,
    range_start: usize,
    range_length: usize,
};

pub const PassiveSpan = struct {
    start_index: usize,
    end_index: usize,
};

// ---------------------------------------------------------------------------
// Rule core (pure; no framework calls)
// ---------------------------------------------------------------------------

/// Find passive-voice constructions: a be-lemma verb followed within a few
/// tokens (skipping adverbs and -ing verbs, so "was quickly thrown" and
/// "is being eaten" match) by a verb whose lemma differs from its surface
/// form (catches irregular participles like made/thrown; misses zero-change
/// participles like "was put" — accepted). Spans are inclusive token-index
/// ranges from the be-verb through the participle.
pub fn findPassives(allocator: std.mem.Allocator, tokens: []const TaggedToken) ![]PassiveSpan {
    var spans: std.ArrayList(PassiveSpan) = .empty;
    errdefer spans.deinit(allocator);

    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        if (!std.mem.eql(u8, tokens[i].tag, "Verb")) continue;
        if (!std.mem.eql(u8, tokens[i].lemma, "be")) continue;
        var j = i + 1;
        var steps: usize = 0;
        while (j < tokens.len and steps < 4) : ({
            j += 1;
            steps += 1;
        }) {
            const t = tokens[j];
            if (std.mem.eql(u8, t.tag, "Adverb")) continue;
            if (std.mem.eql(u8, t.tag, "Verb")) {
                if (std.mem.endsWith(u8, t.token, "ing")) continue;
                if (!std.mem.eql(u8, t.token, t.lemma)) {
                    try spans.append(allocator, .{ .start_index = i, .end_index = j });
                    i = j; // resume after the participle so inner be-verbs don't re-match
                }
                break;
            }
            break; // any other part of speech ends the scan
        }
    }
    return spans.toOwnedSlice(allocator);
}

pub fn countAdverbs(tokens: []const TaggedToken) usize {
    var count: usize = 0;
    for (tokens) |t| {
        if (std.mem.eql(u8, t.tag, "Adverb")) count += 1;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Orchestration (composes the nlp module; macOS-backed)
// ---------------------------------------------------------------------------

/// Analyze text for style findings, sorted by range start. Ranges are
/// absolute UTF-16 code-unit offsets. Caller frees via freeStyleIssues.
pub fn analyze(allocator: std.mem.Allocator, text: []const u8, opts: Options) nlp.NlpError![]StyleIssue {
    var issues: std.ArrayList(StyleIssue) = .empty;
    errdefer {
        for (issues.items) |it| {
            allocator.free(it.value);
            allocator.free(it.description);
        }
        issues.deinit(allocator);
    }

    const sentences = try nlp.tokenize(allocator, text, .sentence);
    defer nlp.freeTokenResults(allocator, sentences);

    for (sentences) |sentence| {
        const words = try nlp.tokenize(allocator, sentence.token, .word);
        defer nlp.freeTokenResults(allocator, words);
        const pos_tags = try nlp.tagPartsOfSpeech(allocator, sentence.token);
        defer nlp.freePosTags(allocator, pos_tags);
        const lemmas = try nlp.lemmatize(allocator, sentence.token);
        defer nlp.freeLemmaResults(allocator, lemmas);

        // All three derive from the same word segmentation, so they align
        // index-for-index; zip to the shortest to stay in bounds if they
        // ever disagree.
        const n = @min(words.len, @min(pos_tags.len, lemmas.len));
        const tagged = allocator.alloc(TaggedToken, n) catch return nlp.NlpError.OutOfMemory;
        defer allocator.free(tagged);
        for (0..n) |k| {
            tagged[k] = .{
                .token = words[k].token,
                .tag = pos_tags[k].tag,
                .lemma = lemmas[k].lemma,
                .range_start = words[k].range_start,
                .range_length = words[k].range_length,
            };
        }

        // Passive voice
        const spans = findPassives(allocator, tagged) catch return nlp.NlpError.OutOfMemory;
        defer allocator.free(spans);
        for (spans) |span| {
            const first = tagged[span.start_index];
            const last = tagged[span.end_index];
            const value = joinTokens(allocator, tagged[span.start_index .. span.end_index + 1]) catch return nlp.NlpError.OutOfMemory;
            const description = std.fmt.allocPrint(allocator, "passive voice: '{s}'", .{value}) catch return nlp.NlpError.OutOfMemory;
            issues.append(allocator, .{
                .rule = .passive,
                .value = value,
                .description = description,
                .range_start = sentence.range_start + first.range_start,
                .range_length = (last.range_start + last.range_length) - first.range_start,
            }) catch return nlp.NlpError.OutOfMemory;
        }

        // Adverb density
        const adverb_count = countAdverbs(tagged);
        if (adverb_count >= opts.max_adverbs) {
            const value = allocator.dupe(u8, sentence.token) catch return nlp.NlpError.OutOfMemory;
            const description = std.fmt.allocPrint(allocator, "{d} adverbs in one sentence", .{adverb_count}) catch return nlp.NlpError.OutOfMemory;
            issues.append(allocator, .{
                .rule = .adverbs,
                .value = value,
                .description = description,
                .range_start = sentence.range_start,
                .range_length = sentence.range_length,
            }) catch return nlp.NlpError.OutOfMemory;
        }

        // Sentence length
        if (words.len > opts.max_words) {
            const value = allocator.dupe(u8, sentence.token) catch return nlp.NlpError.OutOfMemory;
            const description = std.fmt.allocPrint(allocator, "sentence has {d} words (max {d})", .{ words.len, opts.max_words }) catch return nlp.NlpError.OutOfMemory;
            issues.append(allocator, .{
                .rule = .sentence_length,
                .value = value,
                .description = description,
                .range_start = sentence.range_start,
                .range_length = sentence.range_length,
            }) catch return nlp.NlpError.OutOfMemory;
        }
    }

    const owned = issues.toOwnedSlice(allocator) catch return nlp.NlpError.OutOfMemory;
    std.mem.sort(StyleIssue, owned, {}, struct {
        fn lessThan(_: void, a: StyleIssue, b: StyleIssue) bool {
            return a.range_start < b.range_start;
        }
    }.lessThan);
    return owned;
}

pub fn freeStyleIssues(allocator: std.mem.Allocator, issues: []StyleIssue) void {
    for (issues) |i| {
        allocator.free(i.value);
        allocator.free(i.description);
    }
    allocator.free(issues);
}

/// Join token surface forms with single spaces (display text for spans;
/// avoids slicing UTF-8 bytes by UTF-16 offsets).
fn joinTokens(allocator: std.mem.Allocator, tokens: []const TaggedToken) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (tokens, 0..) |t, i| {
        if (i > 0) try out.writer.print(" ", .{});
        try out.writer.print("{s}", .{t.token});
    }
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn tt(token: []const u8, tag: []const u8, lemma: []const u8) TaggedToken {
    return .{ .token = token, .tag = tag, .lemma = lemma, .range_start = 0, .range_length = 0 };
}

test "findPassives: simple passive" {
    const allocator = std.testing.allocator;
    const tokens = [_]TaggedToken{
        tt("Mistakes", "Noun", "mistake"),
        tt("were", "Verb", "be"),
        tt("made", "Verb", "make"),
        tt("by", "Preposition", "by"),
    };
    const spans = try findPassives(allocator, &tokens);
    defer allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqual(@as(usize, 1), spans[0].start_index);
    try std.testing.expectEqual(@as(usize, 2), spans[0].end_index);
}

test "findPassives: intervening adverb" {
    const allocator = std.testing.allocator;
    const tokens = [_]TaggedToken{
        tt("was", "Verb", "be"),
        tt("quickly", "Adverb", "quickly"),
        tt("thrown", "Verb", "throw"),
    };
    const spans = try findPassives(allocator, &tokens);
    defer allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqual(@as(usize, 0), spans[0].start_index);
    try std.testing.expectEqual(@as(usize, 2), spans[0].end_index);
}

test "findPassives: skips -ing verb ('is being eaten') without double-counting" {
    const allocator = std.testing.allocator;
    const tokens = [_]TaggedToken{
        tt("is", "Verb", "be"),
        tt("being", "Verb", "be"),
        tt("eaten", "Verb", "eat"),
    };
    const spans = try findPassives(allocator, &tokens);
    defer allocator.free(spans);
    // One span (is..eaten); the inner be-verb 'being' must not produce a second.
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqual(@as(usize, 0), spans[0].start_index);
    try std.testing.expectEqual(@as(usize, 2), spans[0].end_index);
}

test "findPassives: progressive is not passive" {
    const allocator = std.testing.allocator;
    const tokens = [_]TaggedToken{
        tt("was", "Verb", "be"),
        tt("running", "Verb", "run"),
        tt("to", "Preposition", "to"),
    };
    const spans = try findPassives(allocator, &tokens);
    defer allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 0), spans.len);
}

test "findPassives: predicate adjective is not passive" {
    const allocator = std.testing.allocator;
    const tokens = [_]TaggedToken{
        tt("was", "Verb", "be"),
        tt("very", "Adverb", "very"),
        tt("tired", "Adjective", "tired"),
    };
    const spans = try findPassives(allocator, &tokens);
    defer allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 0), spans.len);
}

test "findPassives: zero-change participle is a documented miss" {
    const allocator = std.testing.allocator;
    const tokens = [_]TaggedToken{
        tt("was", "Verb", "be"),
        tt("put", "Verb", "put"),
    };
    const spans = try findPassives(allocator, &tokens);
    defer allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 0), spans.len);
}

test "findPassives: two passives in one sentence" {
    const allocator = std.testing.allocator;
    const tokens = [_]TaggedToken{
        tt("was", "Verb", "be"),
        tt("thrown", "Verb", "throw"),
        tt("and", "Conjunction", "and"),
        tt("was", "Verb", "be"),
        tt("made", "Verb", "make"),
    };
    const spans = try findPassives(allocator, &tokens);
    defer allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqual(@as(usize, 3), spans[1].start_index);
    try std.testing.expectEqual(@as(usize, 4), spans[1].end_index);
}

test "countAdverbs" {
    const tokens = [_]TaggedToken{
        tt("She", "Pronoun", "she"),
        tt("quickly", "Adverb", "quickly"),
        tt("ran", "Verb", "run"),
        tt("extremely", "Adverb", "extremely"),
        tt("fast", "Adverb", "fast"),
    };
    try std.testing.expectEqual(@as(usize, 3), countAdverbs(&tokens));
}
