const std = @import("std");
const builtin = @import("builtin");
const nlp = @import("nlp");
const lsp = @import("lsp.zig");
const style = @import("style.zig");

const version = "0.5.0";

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.print(
        \\Usage: lingua <command> [options] [text]
        \\
        \\Natural language processing CLI powered by native macOS APIs.
        \\Version {s} ({s})
        \\
        \\Commands:
        \\  detect     Identify the language of input text
        \\  sentiment  Analyze text sentiment (-1.0 to 1.0)
        \\  entities   Extract structured data (phones, emails, dates, addresses, URLs)
        \\  ner        Extract named entities (people, places, organizations)
        \\  lemma      Lemmatize words (base/dictionary forms)
        \\  pos        Part-of-speech tagging
        \\  tokenize   Tokenize text into words, sentences, or paragraphs
        \\  grammar    Check grammar (exit 1 if issues found)
        \\  spell      Check spelling (exit 1 if issues found)
        \\  lsp        Run an LSP server (grammar/spelling diagnostics for editors)
        \\  style      Check writing style: passive voice, adverbs, length (exit 1 if issues found)
        \\  define     Look up a dictionary definition (exit 1 if not found)
        \\  help       Show this help message
        \\  completions  Generate shell completion scripts (bash, zsh, fish)
        \\
        \\Input:
        \\  Text can be provided as a trailing argument or piped via stdin.
        \\  echo "Hello world" | lingua detect
        \\  lingua detect "Hello world"
        \\
        \\Global options:
        \\  --json               Output as JSON
        \\  --version, -v        Show version
        \\  --help, -h           Show this help message
        \\
        \\Command-specific options:
        \\  detect:
        \\    --top=N            Show top N candidates (default: 1)
        \\
        \\  sentiment:
        \\    --per-sentence     Score each sentence individually
        \\
        \\  tokenize:
        \\    --unit=UNIT        word, sentence, paragraph (default: word)
        \\
        \\  ner:
        \\    --merge            Merge adjacent tokens with the same entity tag
        \\
        \\  entities:
        \\    --type=TYPE        Filter: phone,email,address,date,url,transit,all (default: all)
        \\
        \\  grammar, spell:
        \\    --lang=XX          Force language (default: auto-detect)
        \\
        \\  style:
        \\    --max-words=N      Flag sentences longer than N words (default: 30)
        \\    --max-adverbs=N    Flag sentences with N or more adverbs (default: 3)
        \\
        \\Created by George Mandis <george@mand.is>
        \\
    , .{ version, @tagName(builtin.os.tag) });
}

fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.print("\\\"", .{}),
            '\\' => try writer.print("\\\\", .{}),
            '\n' => try writer.print("\\n", .{}),
            '\r' => try writer.print("\\r", .{}),
            '\t' => try writer.print("\\t", .{}),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try writer.print("\\u{X:0>4}", .{c}),
            else => try writer.print("{c}", .{c}),
        }
    }
}

fn readStdin(allocator: std.mem.Allocator, init: std.process.Init) ![]const u8 {
    const stdin_file = std.Io.File.stdin();
    const stdin_is_tty = stdin_file.isTty(init.io) catch false;
    if (stdin_is_tty) return error.NoInput;

    var stdin_buf: [4096]u8 = undefined;
    var reader = stdin_file.readerStreaming(init.io, &stdin_buf);

    var result: std.ArrayList(u8) = .empty;
    while (true) {
        const byte = reader.interface.takeByte() catch break;
        result.append(allocator, byte) catch return error.OutOfMemory;
    }

    // Trim trailing whitespace
    var data = result.toOwnedSlice(allocator) catch return error.OutOfMemory;
    var end = data.len;
    while (end > 0 and (data[end - 1] == '\n' or data[end - 1] == '\r' or data[end - 1] == ' ')) {
        end -= 1;
    }
    if (end < data.len) {
        const trimmed = allocator.dupe(u8, data[0..end]) catch return error.OutOfMemory;
        allocator.free(data);
        return trimmed;
    }
    return data;
}

fn getInputText(allocator: std.mem.Allocator, args_iter: anytype, init: std.process.Init) ![]const u8 {
    // Check for remaining positional arg
    if (args_iter.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            return allocator.dupe(u8, arg) catch return error.OutOfMemory;
        }
    }

    // Fall back to stdin
    return readStdin(allocator, init);
}

// ---------------------------------------------------------------------------
// Command handlers
// ---------------------------------------------------------------------------

fn cmdDetect(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    text: []const u8,
    json_mode: bool,
    top_n: usize,
) !void {
    const results = nlp.detectLanguage(allocator, text, top_n) catch |err| {
        return printNlpError(writer, err, json_mode);
    };
    defer nlp.freeLanguageResults(allocator, results);

    if (json_mode) {
        if (results.len == 1) {
            try writer.print("{{\"language\":\"", .{});
            try writeJsonString(writer, results[0].language);
            try writer.print("\",\"confidence\":{d:.4}}}\n", .{results[0].confidence});
        } else {
            try writer.print("[", .{});
            for (results, 0..) |r, i| {
                if (i > 0) try writer.print(",", .{});
                try writer.print("{{\"language\":\"", .{});
                try writeJsonString(writer, r.language);
                try writer.print("\",\"confidence\":{d:.4}}}", .{r.confidence});
            }
            try writer.print("]\n", .{});
        }
    } else {
        for (results) |r| {
            try writer.print("{s} [{d:.2}]\n", .{ r.language, r.confidence });
        }
    }
}

fn cmdSentiment(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    text: []const u8,
    json_mode: bool,
    per_sentence: bool,
) !void {
    const results = nlp.analyzeSentiment(allocator, text, per_sentence) catch |err| {
        return printNlpError(writer, err, json_mode);
    };
    defer nlp.freeSentimentResults(allocator, results);

    if (json_mode) {
        if (!per_sentence and results.len == 1) {
            try writer.print("{{\"score\":{d:.4}}}\n", .{results[0].score});
        } else {
            try writer.print("[", .{});
            for (results, 0..) |r, i| {
                if (i > 0) try writer.print(",", .{});
                try writer.print("{{\"text\":\"", .{});
                try writeJsonString(writer, r.text);
                try writer.print("\",\"score\":{d:.4}}}", .{r.score});
            }
            try writer.print("]\n", .{});
        }
    } else {
        if (!per_sentence and results.len == 1) {
            try writer.print("{d:.4}\n", .{results[0].score});
        } else {
            for (results) |r| {
                try writer.print("{d:.4}\t{s}\n", .{ r.score, r.text });
            }
        }
    }
}

fn cmdEntities(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    text: []const u8,
    json_mode: bool,
    type_filter: ?[]const u8,
) !void {
    const results = nlp.detectEntities(allocator, text) catch |err| {
        return printNlpError(writer, err, json_mode);
    };
    defer nlp.freeDetectedEntities(allocator, results);

    if (json_mode) {
        try writer.print("[", .{});
        var first = true;
        for (results) |r| {
            if (type_filter) |filter| {
                if (!std.mem.eql(u8, filter, "all") and !std.mem.eql(u8, filter, r.entity_type)) continue;
            }
            if (!first) try writer.print(",", .{});
            try writer.print("{{\"type\":\"", .{});
            try writeJsonString(writer, r.entity_type);
            try writer.print("\",\"value\":\"", .{});
            try writeJsonString(writer, r.value);
            try writer.print("\",\"range\":[{d},{d}]}}", .{ r.range_start, r.range_length });
            first = false;
        }
        try writer.print("]\n", .{});
    } else {
        for (results) |r| {
            if (type_filter) |filter| {
                if (!std.mem.eql(u8, filter, "all") and !std.mem.eql(u8, filter, r.entity_type)) continue;
            }
            try writer.print("{s}: {s}\n", .{ r.entity_type, r.value });
        }
    }
}

fn cmdNer(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    text: []const u8,
    json_mode: bool,
    merge: bool,
) !void {
    const raw_results = nlp.extractNamedEntities(allocator, text) catch |err| {
        return printNlpError(writer, err, json_mode);
    };

    if (!merge) {
        defer nlp.freeEntityTags(allocator, raw_results);
        if (json_mode) {
            try writer.print("[", .{});
            for (raw_results, 0..) |r, i| {
                if (i > 0) try writer.print(",", .{});
                try writer.print("{{\"token\":\"", .{});
                try writeJsonString(writer, r.token);
                try writer.print("\",\"tag\":\"", .{});
                try writeJsonString(writer, r.tag);
                try writer.print("\",\"range\":[{d},{d}]}}", .{ r.range_start, r.range_length });
            }
            try writer.print("]\n", .{});
        } else {
            for (raw_results) |r| {
                try writer.print("{s}: {s}\n", .{ r.tag, r.token });
            }
        }
        return;
    }

    // Merge adjacent tokens with the same tag
    defer nlp.freeEntityTags(allocator, raw_results);
    var merged: std.ArrayList(nlp.EntityTag) = .empty;
    defer {
        for (merged.items) |m| {
            allocator.free(m.token);
            // tag is shared/duped below, free it
            allocator.free(m.tag);
        }
        merged.deinit(allocator);
    }

    for (raw_results) |r| {
        if (merged.items.len > 0) {
            const prev = &merged.items[merged.items.len - 1];
            if (std.mem.eql(u8, prev.tag, r.tag) and
                (prev.range_start + prev.range_length) <= r.range_start and
                r.range_start - (prev.range_start + prev.range_length) <= 1)
            {
                // Merge: extend the token text
                const gap_len = r.range_start - (prev.range_start + prev.range_length);
                const new_len = prev.token.len + gap_len + r.token.len;
                const new_token = allocator.alloc(u8, new_len) catch continue;
                @memcpy(new_token[0..prev.token.len], prev.token);
                if (gap_len > 0) {
                    new_token[prev.token.len] = ' ';
                }
                @memcpy(new_token[prev.token.len + gap_len ..], r.token);
                allocator.free(prev.token);
                prev.token = new_token;
                prev.range_length = (r.range_start + r.range_length) - prev.range_start;
                continue;
            }
        }
        merged.append(allocator, .{
            .token = allocator.dupe(u8, r.token) catch continue,
            .tag = allocator.dupe(u8, r.tag) catch continue,
            .range_start = r.range_start,
            .range_length = r.range_length,
        }) catch continue;
    }

    if (json_mode) {
        try writer.print("[", .{});
        for (merged.items, 0..) |r, i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print("{{\"token\":\"", .{});
            try writeJsonString(writer, r.token);
            try writer.print("\",\"tag\":\"", .{});
            try writeJsonString(writer, r.tag);
            try writer.print("\",\"range\":[{d},{d}]}}", .{ r.range_start, r.range_length });
        }
        try writer.print("]\n", .{});
    } else {
        for (merged.items) |r| {
            try writer.print("{s}: {s}\n", .{ r.tag, r.token });
        }
    }
}

fn cmdLemma(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    text: []const u8,
    json_mode: bool,
) !void {
    const results = nlp.lemmatize(allocator, text) catch |err| {
        return printNlpError(writer, err, json_mode);
    };
    defer nlp.freeLemmaResults(allocator, results);

    if (json_mode) {
        try writer.print("[", .{});
        for (results, 0..) |r, i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print("{{\"token\":\"", .{});
            try writeJsonString(writer, r.token);
            try writer.print("\",\"lemma\":\"", .{});
            try writeJsonString(writer, r.lemma);
            try writer.print("\"}}", .{});
        }
        try writer.print("]\n", .{});
    } else {
        for (results, 0..) |r, i| {
            if (i > 0) try writer.print(" ", .{});
            if (std.mem.eql(u8, r.token, r.lemma)) {
                try writer.print("{s}", .{r.token});
            } else {
                try writer.print("{s}/{s}", .{ r.token, r.lemma });
            }
        }
        try writer.print("\n", .{});
    }
}

fn cmdPos(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    text: []const u8,
    json_mode: bool,
) !void {
    const results = nlp.tagPartsOfSpeech(allocator, text) catch |err| {
        return printNlpError(writer, err, json_mode);
    };
    defer nlp.freePosTags(allocator, results);

    if (json_mode) {
        try writer.print("[", .{});
        for (results, 0..) |r, i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print("{{\"token\":\"", .{});
            try writeJsonString(writer, r.token);
            try writer.print("\",\"tag\":\"", .{});
            try writeJsonString(writer, r.tag);
            try writer.print("\"}}", .{});
        }
        try writer.print("]\n", .{});
    } else {
        for (results, 0..) |r, i| {
            if (i > 0) try writer.print(" ", .{});
            try writer.print("{s}/{s}", .{ r.token, r.tag });
        }
        try writer.print("\n", .{});
    }
}

fn cmdTokenize(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    text: []const u8,
    json_mode: bool,
    unit: nlp.TokenUnit,
) !void {
    const results = nlp.tokenize(allocator, text, unit) catch |err| {
        return printNlpError(writer, err, json_mode);
    };
    defer nlp.freeTokenResults(allocator, results);

    if (json_mode) {
        try writer.print("[", .{});
        for (results, 0..) |r, i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print("\"", .{});
            try writeJsonString(writer, r.token);
            try writer.print("\"", .{});
        }
        try writer.print("]\n", .{});
    } else {
        for (results) |r| {
            try writer.print("{s}\n", .{r.token});
        }
    }
}

fn cmdGrammar(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    text: []const u8,
    json_mode: bool,
    lang: ?[]const u8,
) !usize {
    const results = nlp.checkGrammar(allocator, text, lang) catch |err| {
        try printNlpError(writer, err, json_mode);
        try writer.flush();
        std.process.exit(2);
    };
    defer nlp.freeGrammarIssues(allocator, results);

    if (json_mode) {
        try writer.print("[", .{});
        for (results, 0..) |r, i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print("{{\"type\":\"grammar\",\"value\":\"", .{});
            try writeJsonString(writer, r.value);
            try writer.print("\",\"description\":\"", .{});
            try writeJsonString(writer, r.description);
            try writer.print("\",\"corrections\":[", .{});
            for (r.corrections, 0..) |c, ci| {
                if (ci > 0) try writer.print(",", .{});
                try writer.print("\"", .{});
                try writeJsonString(writer, c);
                try writer.print("\"", .{});
            }
            try writer.print("],\"range\":[{d},{d}]}}", .{ r.range_start, r.range_length });
        }
        try writer.print("]\n", .{});
    } else {
        for (results) |r| {
            try writer.print("grammar: {s}", .{r.description});
            if (r.corrections.len > 0) {
                try writer.print(" -> ", .{});
                for (r.corrections, 0..) |ci_i, ci| {
                    if (ci > 0) try writer.print(", ", .{});
                    try writer.print("{s}", .{ci_i});
                }
            }
            try writer.print(" [{d},{d}]\n", .{ r.range_start, r.range_length });
        }
    }
    return results.len;
}

fn cmdSpell(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    text: []const u8,
    json_mode: bool,
    lang: ?[]const u8,
) !usize {
    const results = nlp.checkSpelling(allocator, text, lang) catch |err| {
        try printNlpError(writer, err, json_mode);
        try writer.flush();
        std.process.exit(2);
    };
    defer nlp.freeSpellingIssues(allocator, results);

    if (json_mode) {
        try writer.print("[", .{});
        for (results, 0..) |r, i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print("{{\"type\":\"spelling\",\"value\":\"", .{});
            try writeJsonString(writer, r.word);
            try writer.print("\",\"corrections\":[", .{});
            for (r.guesses, 0..) |g, gi| {
                if (gi > 0) try writer.print(",", .{});
                try writer.print("\"", .{});
                try writeJsonString(writer, g);
                try writer.print("\"", .{});
            }
            try writer.print("],\"range\":[{d},{d}]}}", .{ r.range_start, r.range_length });
        }
        try writer.print("]\n", .{});
    } else {
        for (results) |r| {
            try writer.print("spell: {s}", .{r.word});
            if (r.guesses.len > 0) {
                try writer.print(" -> ", .{});
                const max_shown = @min(r.guesses.len, 3);
                for (r.guesses[0..max_shown], 0..) |g, gi| {
                    if (gi > 0) try writer.print(", ", .{});
                    try writer.print("{s}", .{g});
                }
            }
            try writer.print(" [{d},{d}]\n", .{ r.range_start, r.range_length });
        }
    }
    return results.len;
}

fn cmdStyle(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    text: []const u8,
    json_mode: bool,
    opts: style.Options,
) !usize {
    const results = style.analyze(allocator, text, opts) catch |err| {
        try printNlpError(writer, err, json_mode);
        try writer.flush();
        std.process.exit(2);
    };
    defer style.freeStyleIssues(allocator, results);

    if (json_mode) {
        try writer.print("[", .{});
        for (results, 0..) |r, i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print("{{\"type\":\"style\",\"rule\":\"{s}\",\"value\":\"", .{style.ruleName(r.rule)});
            try writeJsonString(writer, r.value);
            try writer.print("\",\"description\":\"", .{});
            try writeJsonString(writer, r.description);
            try writer.print("\",\"range\":[{d},{d}]}}", .{ r.range_start, r.range_length });
        }
        try writer.print("]\n", .{});
    } else {
        for (results) |r| {
            try writer.print("style: {s} [{d},{d}]\n", .{ r.description, r.range_start, r.range_length });
        }
    }
    return results.len;
}

fn cmdDefine(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    term: []const u8,
    json_mode: bool,
) !bool {
    const definition = nlp.define(allocator, term) catch |err| {
        try printNlpError(writer, err, json_mode);
        try writer.flush();
        std.process.exit(2);
    };
    const def = definition orelse return false;
    defer allocator.free(def);

    if (json_mode) {
        try writer.print("{{\"term\":\"", .{});
        try writeJsonString(writer, term);
        try writer.print("\",\"definition\":\"", .{});
        try writeJsonString(writer, def);
        try writer.print("\"}}\n", .{});
    } else {
        try writer.print("{s}\n", .{def});
    }
    return true;
}

fn cmdCompletions(writer: *std.Io.Writer, shell: []const u8) !void {
    if (std.mem.eql(u8, shell, "bash")) {
        try writer.print(
            \\_lingua() {{
            \\    local cur prev words cword
            \\    _init_completion || return
            \\
            \\    local commands="detect sentiment entities ner lemma pos tokenize grammar spell style lsp help completions"
            \\
            \\    if [[ $cword -eq 1 ]]; then
            \\        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
            \\        return
            \\    fi
            \\
            \\    case "${{words[1]}}" in
            \\        detect)
            \\            COMPREPLY=($(compgen -W "--top= --json" -- "$cur"))
            \\            ;;
            \\        sentiment)
            \\            COMPREPLY=($(compgen -W "--per-sentence --json" -- "$cur"))
            \\            ;;
            \\        entities)
            \\            COMPREPLY=($(compgen -W "--type= --json" -- "$cur"))
            \\            ;;
            \\        ner)
            \\            COMPREPLY=($(compgen -W "--merge --json" -- "$cur"))
            \\            ;;
            \\        lemma|pos)
            \\            COMPREPLY=($(compgen -W "--json" -- "$cur"))
            \\            ;;
            \\        tokenize)
            \\            COMPREPLY=($(compgen -W "--unit= --json" -- "$cur"))
            \\            ;;
            \\        grammar|spell)
            \\            COMPREPLY=($(compgen -W "--lang= --json" -- "$cur"))
            \\            ;;
            \\        style)
            \\            COMPREPLY=($(compgen -W "--max-words= --max-adverbs= --json" -- "$cur"))
            \\            ;;
            \\        completions)
            \\            COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur"))
            \\            ;;
            \\        *)
            \\            ;;
            \\    esac
            \\}}
            \\
            \\complete -F _lingua lingua
            \\
        , .{});
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try writer.print(
            \\#compdef lingua
            \\
            \\_lingua() {{
            \\    local -a commands
            \\    commands=(
            \\        'detect:Identify the language of input text'
            \\        'sentiment:Analyze text sentiment'
            \\        'entities:Extract structured data'
            \\        'ner:Extract named entities'
            \\        'lemma:Lemmatize words'
            \\        'pos:Part-of-speech tagging'
            \\        'tokenize:Tokenize text'
            \\        'grammar:Check grammar'
            \\        'spell:Check spelling'
            \\        'style:Check writing style'
            \\        'lsp:Run an LSP server'
            \\        'help:Show help message'
            \\        'completions:Generate shell completion scripts'
            \\    )
            \\
            \\    _arguments -C \
            \\        '(-h --help)'{{-h,--help}}'[Show help]' \
            \\        '(-v --version)'{{-v,--version}}'[Show version]' \
            \\        '--json[Output as JSON]' \
            \\        '1: :->command' \
            \\        '*:: :->args'
            \\
            \\    case $state in
            \\        command)
            \\            _describe 'command' commands
            \\            ;;
            \\        args)
            \\            case $words[1] in
            \\                detect)
            \\                    _arguments \
            \\                        '--top=[Show top N candidates]:N' \
            \\                        '--json[Output as JSON]'
            \\                    ;;
            \\                sentiment)
            \\                    _arguments \
            \\                        '--per-sentence[Score each sentence individually]' \
            \\                        '--json[Output as JSON]'
            \\                    ;;
            \\                entities)
            \\                    _arguments \
            \\                        '--type=[Filter entity type]:type:(phone email address date url transit all)' \
            \\                        '--json[Output as JSON]'
            \\                    ;;
            \\                ner)
            \\                    _arguments \
            \\                        '--merge[Merge adjacent tokens with the same entity tag]' \
            \\                        '--json[Output as JSON]'
            \\                    ;;
            \\                lemma|pos)
            \\                    _arguments '--json[Output as JSON]'
            \\                    ;;
            \\                tokenize)
            \\                    _arguments \
            \\                        '--unit=[Tokenize unit]:unit:(word sentence paragraph)' \
            \\                        '--json[Output as JSON]'
            \\                    ;;
            \\                grammar|spell)
            \\                    _arguments \
            \\                        '--lang=[Force language]:lang' \
            \\                        '--json[Output as JSON]'
            \\                    ;;
            \\                style)
            \\                    _arguments \
            \\                        '--max-words=[Flag sentences longer than N words]:N' \
            \\                        '--max-adverbs=[Flag sentences with N or more adverbs]:N' \
            \\                        '--json[Output as JSON]'
            \\                    ;;
            \\                completions)
            \\                    local -a shells
            \\                    shells=('bash' 'zsh' 'fish')
            \\                    _describe 'shell' shells
            \\                    ;;
            \\            esac
            \\            ;;
            \\    esac
            \\}}
            \\
            \\_lingua "$@"
            \\
        , .{});
    } else if (std.mem.eql(u8, shell, "fish")) {
        try writer.print(
            \\# Remove all existing completions for lingua
            \\complete -e -c lingua
            \\
            \\# Disable file completions for lingua
            \\complete -c lingua -f
            \\
            \\# Top-level commands
            \\complete -c lingua -n '__fish_use_subcommand' -a detect     -d 'Identify the language of input text'
            \\complete -c lingua -n '__fish_use_subcommand' -a sentiment  -d 'Analyze text sentiment'
            \\complete -c lingua -n '__fish_use_subcommand' -a entities   -d 'Extract structured data'
            \\complete -c lingua -n '__fish_use_subcommand' -a ner        -d 'Extract named entities'
            \\complete -c lingua -n '__fish_use_subcommand' -a lemma      -d 'Lemmatize words'
            \\complete -c lingua -n '__fish_use_subcommand' -a pos        -d 'Part-of-speech tagging'
            \\complete -c lingua -n '__fish_use_subcommand' -a tokenize   -d 'Tokenize text'
            \\complete -c lingua -n '__fish_use_subcommand' -a grammar    -d 'Check grammar'
            \\complete -c lingua -n '__fish_use_subcommand' -a spell      -d 'Check spelling'
            \\complete -c lingua -n '__fish_use_subcommand' -a style      -d 'Check writing style'
            \\complete -c lingua -n '__fish_use_subcommand' -a lsp        -d 'Run an LSP server'
            \\complete -c lingua -n '__fish_use_subcommand' -a help       -d 'Show help message'
            \\complete -c lingua -n '__fish_use_subcommand' -a completions -d 'Generate shell completion scripts'
            \\
            \\# Global flags
            \\complete -c lingua -l json    -d 'Output as JSON'
            \\complete -c lingua -l version -d 'Show version'
            \\complete -c lingua -s v       -d 'Show version'
            \\complete -c lingua -l help    -d 'Show help'
            \\complete -c lingua -s h       -d 'Show help'
            \\
            \\# detect options
            \\complete -c lingua -n '__fish_seen_subcommand_from detect' -l top  -d 'Show top N candidates' -r
            \\complete -c lingua -n '__fish_seen_subcommand_from detect' -l json -d 'Output as JSON'
            \\
            \\# sentiment options
            \\complete -c lingua -n '__fish_seen_subcommand_from sentiment' -l per-sentence -d 'Score each sentence individually'
            \\complete -c lingua -n '__fish_seen_subcommand_from sentiment' -l json         -d 'Output as JSON'
            \\
            \\# entities options
            \\complete -c lingua -n '__fish_seen_subcommand_from entities' -l type -d 'Filter entity type' -r -a 'phone email address date url transit all'
            \\complete -c lingua -n '__fish_seen_subcommand_from entities' -l json -d 'Output as JSON'
            \\
            \\# ner options
            \\complete -c lingua -n '__fish_seen_subcommand_from ner' -l merge -d 'Merge adjacent tokens with the same entity tag'
            \\complete -c lingua -n '__fish_seen_subcommand_from ner' -l json  -d 'Output as JSON'
            \\
            \\# lemma options
            \\complete -c lingua -n '__fish_seen_subcommand_from lemma' -l json -d 'Output as JSON'
            \\
            \\# pos options
            \\complete -c lingua -n '__fish_seen_subcommand_from pos' -l json -d 'Output as JSON'
            \\
            \\# tokenize options
            \\complete -c lingua -n '__fish_seen_subcommand_from tokenize' -l unit -d 'Tokenize unit' -r -a 'word sentence paragraph'
            \\complete -c lingua -n '__fish_seen_subcommand_from tokenize' -l json -d 'Output as JSON'
            \\
            \\# grammar options
            \\complete -c lingua -n '__fish_seen_subcommand_from grammar' -l lang -d 'Force language' -r
            \\complete -c lingua -n '__fish_seen_subcommand_from grammar' -l json -d 'Output as JSON'
            \\
            \\# spell options
            \\complete -c lingua -n '__fish_seen_subcommand_from spell' -l lang -d 'Force language' -r
            \\complete -c lingua -n '__fish_seen_subcommand_from spell' -l json -d 'Output as JSON'
            \\
            \\# style options
            \\complete -c lingua -n '__fish_seen_subcommand_from style' -l max-words   -d 'Flag sentences longer than N words' -r
            \\complete -c lingua -n '__fish_seen_subcommand_from style' -l max-adverbs -d 'Flag sentences with N or more adverbs' -r
            \\complete -c lingua -n '__fish_seen_subcommand_from style' -l json        -d 'Output as JSON'
            \\
            \\# completions shell argument
            \\complete -c lingua -n '__fish_seen_subcommand_from completions' -a 'bash zsh fish' -d 'Shell type'
            \\
        , .{});
    } else {
        try writer.print("Error: unknown shell '{s}'. Use bash, zsh, or fish.\n", .{shell});
    }
}

fn printNlpError(writer: *std.Io.Writer, err: nlp.NlpError, json_mode: bool) !void {
    const msg: []const u8 = switch (err) {
        nlp.NlpError.FrameworkUnavailable => "NaturalLanguage framework not available",
        nlp.NlpError.DetectionFailed => "Detection failed",
        nlp.NlpError.OutOfMemory => "Out of memory",
        nlp.NlpError.UnsupportedPlatform => "Unsupported platform",
    };
    if (json_mode) {
        try writer.print("{{\"error\":\"{s}\"}}\n", .{msg});
    } else {
        try writer.print("Error: {s}\n", .{msg});
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(init.io, &stdout_buf);

    const stderr_file = std.Io.File.stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(init.io, &stderr_buf);

    const allocator = init.gpa;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip program name

    // Get command
    const command = args_iter.next() orelse {
        try printUsage(&stdout.interface);
        try stdout.interface.flush();
        return;
    };

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        try printUsage(&stdout.interface);
        try stdout.interface.flush();
        return;
    }

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try stdout.interface.print("lingua " ++ version ++ " (" ++ @tagName(builtin.os.tag) ++ ")\n", .{});
        try stdout.interface.flush();
        return;
    }

    if (std.mem.eql(u8, command, "completions")) {
        const shell = args_iter.next() orelse {
            try stderr.interface.print("Error: completions requires a shell argument (bash, zsh, fish)\n", .{});
            try stderr.interface.flush();
            std.process.exit(2);
        };
        try cmdCompletions(&stdout.interface, shell);
        try stdout.interface.flush();
        return;
    }

    if (std.mem.eql(u8, command, "lsp")) {
        try lsp.run(allocator, init, version);
        return;
    }

    // Parse command-specific flags
    var json_mode = false;
    var top_n: usize = 1;
    var per_sentence = false;
    var token_unit: nlp.TokenUnit = .word;
    var type_filter: ?[]const u8 = null;
    var merge_entities = false;
    var lang: ?[]const u8 = null;
    var inline_text: ?[]const u8 = null;
    var max_words: usize = 30;
    var max_adverbs: usize = 3;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--top=")) {
            top_n = std.fmt.parseInt(usize, arg["--top=".len..], 10) catch {
                try stderr.interface.print("Error: invalid --top value\n", .{});
                try stderr.interface.flush();
                std.process.exit(2);
            };
            if (top_n == 0) top_n = 1;
        } else if (std.mem.eql(u8, arg, "--per-sentence")) {
            per_sentence = true;
        } else if (std.mem.startsWith(u8, arg, "--unit=")) {
            const unit_str = arg["--unit=".len..];
            if (std.mem.eql(u8, unit_str, "word")) {
                token_unit = .word;
            } else if (std.mem.eql(u8, unit_str, "sentence")) {
                token_unit = .sentence;
            } else if (std.mem.eql(u8, unit_str, "paragraph")) {
                token_unit = .paragraph;
            } else {
                try stderr.interface.print("Error: unknown unit '{s}' (use word, sentence, or paragraph)\n", .{unit_str});
                try stderr.interface.flush();
                std.process.exit(2);
            }
        } else if (std.mem.eql(u8, arg, "--merge")) {
            merge_entities = true;
        } else if (std.mem.startsWith(u8, arg, "--type=")) {
            type_filter = arg["--type=".len..];
        } else if (std.mem.startsWith(u8, arg, "--lang=")) {
            lang = arg["--lang=".len..];
        } else if (std.mem.startsWith(u8, arg, "--max-words=")) {
            max_words = std.fmt.parseInt(usize, arg["--max-words=".len..], 10) catch {
                try stderr.interface.print("Error: invalid --max-words value\n", .{});
                try stderr.interface.flush();
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--max-adverbs=")) {
            max_adverbs = std.fmt.parseInt(usize, arg["--max-adverbs=".len..], 10) catch {
                try stderr.interface.print("Error: invalid --max-adverbs value\n", .{});
                try stderr.interface.flush();
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.interface.print("Error: unknown flag: {s}\n", .{arg});
            try stderr.interface.flush();
            std.process.exit(2);
        } else {
            // Positional argument = inline text
            if (inline_text == null) {
                inline_text = arg;
            }
        }
    }

    // Commands for which missing/empty input is a usage error (exit 2).
    const strict_input = std.mem.eql(u8, command, "grammar") or std.mem.eql(u8, command, "spell") or
        std.mem.eql(u8, command, "style") or std.mem.eql(u8, command, "define");

    // Get input text
    const text = if (inline_text) |t|
        allocator.dupe(u8, t) catch {
            try stderr.interface.print("Error: out of memory\n", .{});
            try stderr.interface.flush();
            std.process.exit(1);
        }
    else
        readStdin(allocator, init) catch {
            try stderr.interface.print("Error: no input text. Provide text as an argument or pipe via stdin.\n", .{});
            try stderr.interface.flush();
            std.process.exit(if (strict_input) 2 else 1);
        };
    defer allocator.free(text);

    if (text.len == 0) {
        try stderr.interface.print("Error: empty input\n", .{});
        try stderr.interface.flush();
        std.process.exit(if (strict_input) 2 else 1);
    }

    // Dispatch to command handler
    if (std.mem.eql(u8, command, "detect")) {
        try cmdDetect(&stdout.interface, allocator, text, json_mode, top_n);
    } else if (std.mem.eql(u8, command, "sentiment")) {
        try cmdSentiment(&stdout.interface, allocator, text, json_mode, per_sentence);
    } else if (std.mem.eql(u8, command, "entities")) {
        try cmdEntities(&stdout.interface, allocator, text, json_mode, type_filter);
    } else if (std.mem.eql(u8, command, "ner")) {
        try cmdNer(&stdout.interface, allocator, text, json_mode, merge_entities);
    } else if (std.mem.eql(u8, command, "lemma")) {
        try cmdLemma(&stdout.interface, allocator, text, json_mode);
    } else if (std.mem.eql(u8, command, "pos")) {
        try cmdPos(&stdout.interface, allocator, text, json_mode);
    } else if (std.mem.eql(u8, command, "tokenize")) {
        try cmdTokenize(&stdout.interface, allocator, text, json_mode, token_unit);
    } else if (std.mem.eql(u8, command, "grammar")) {
        const issue_count = try cmdGrammar(&stdout.interface, allocator, text, json_mode, lang);
        try stdout.interface.flush();
        if (issue_count > 0) std.process.exit(1);
        return;
    } else if (std.mem.eql(u8, command, "spell")) {
        const issue_count = try cmdSpell(&stdout.interface, allocator, text, json_mode, lang);
        try stdout.interface.flush();
        if (issue_count > 0) std.process.exit(1);
        return;
    } else if (std.mem.eql(u8, command, "style")) {
        const issue_count = try cmdStyle(&stdout.interface, allocator, text, json_mode, .{ .max_words = max_words, .max_adverbs = max_adverbs });
        try stdout.interface.flush();
        if (issue_count > 0) std.process.exit(1);
        return;
    } else if (std.mem.eql(u8, command, "define")) {
        const found = try cmdDefine(&stdout.interface, allocator, text, json_mode);
        try stdout.interface.flush();
        if (!found) {
            try stderr.interface.print("No definition found for '{s}'\n", .{text});
            try stderr.interface.flush();
            std.process.exit(1);
        }
        return;
    } else {
        try stderr.interface.print("Error: unknown command '{s}'\n\n", .{command});
        try printUsage(&stderr.interface);
        try stderr.interface.flush();
        std.process.exit(2);
    }

    try stdout.interface.flush();
}
