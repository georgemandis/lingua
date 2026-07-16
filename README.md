# lingua

Natural language processing from the command line, powered by native macOS APIs.

Language detection, sentiment analysis, part-of-speech tagging, named entity recognition, structured entity extraction (phone numbers, emails, addresses, dates, flight numbers), spelling, grammar, and style checking, dictionary definitions, an English LSP server, and tokenization — all on-device, no API keys, no downloads, no network calls.

Written in Zig. Uses Apple's NaturalLanguage framework, NSSpellChecker, and NSDataDetector via Objective-C runtime bindings.

## Install

### Homebrew

```bash
brew install georgemandis/tap/lingua
```

### From source

Requires [Zig 0.16+](https://ziglang.org/download/) and macOS.

```bash
git clone https://github.com/georgemandis/lingua.git
cd lingua
zig build -Doptimize=ReleaseFast
```

## Usage

Text can be piped via stdin or provided as an argument.

### Language Detection

```bash
$ echo "Bonjour le monde" | lingua detect
fr [0.98]

$ echo "Hello world" | lingua detect --top=3 --json
[{"language":"en","confidence":0.9158},{"language":"id","confidence":0.0124},{"language":"sv","confidence":0.0093}]
```

### Sentiment Analysis

Score from -1.0 (negative) to 1.0 (positive).

```bash
$ echo "The food was absolutely incredible" | lingua sentiment
1.0000

$ echo "I hate this terrible product" | lingua sentiment
-1.0000

$ echo "I love this. I hate that. It was okay." | lingua sentiment --per-sentence
1.0000	I love this.
-0.6000	I hate that.
-0.8000	It was okay.
```

### Entity Extraction

Extract phone numbers, email addresses, physical addresses, dates, URLs, and flight/transit numbers using NSDataDetector.

```bash
$ echo "Call 800-555-1212 or email bob@test.com on March 3rd" | lingua entities
phone: 800-555-1212
email: bob@test.com
date: March 3rd

$ echo "Meet at 123 Main St, Springfield IL. Flight AA 123." | lingua entities --json
[{"type":"address","value":"123 Main St, Springfield IL","range":[8,27]},{"type":"transit","value":"AA 123","range":[37,6]}]

$ echo "Call 555-1234 or email me@test.com" | lingua entities --type=phone
phone: 555-1234
```

### Named Entity Recognition

Identify people, places, and organizations using NLTagger.

```bash
$ echo "Tim Cook announced new products at Apple headquarters in Cupertino" | lingua ner
PersonalName: Tim
PersonalName: Cook
OrganizationName: Apple
PlaceName: Cupertino
```

### Part-of-Speech Tagging

```bash
$ echo "The cat sat on the mat" | lingua pos
The/Determiner cat/Noun sat/Verb on/Preposition the/Determiner mat/Noun

$ echo "The cat sat" | lingua pos --json
[{"token":"The","tag":"Determiner"},{"token":"cat","tag":"Noun"},{"token":"sat","tag":"Verb"}]
```

### Tokenization

```bash
$ echo "Hello world. How are you?" | lingua tokenize
Hello
world
How
are
you

$ echo "Hello world. How are you?" | lingua tokenize --unit=sentence
Hello world.
How are you?
```

### Spell Checking

Check spelling using the same engine behind TextEdit's squiggles. Exits 1 if issues are found, 0 if clean — pipe-friendly for scripts and CI.

```bash
$ echo "The recieved package was definately late" | lingua spell
spell: recieved -> received, relieved [4,8]
spell: definately -> definitely, defiantly [25,10]

$ echo "I recieve packages" | lingua spell --json
[{"type":"spelling","value":"recieve","corrections":["receive","relieve"],"range":[2,7]}]
```

### Grammar Checking

Informal grammar checking via NSSpellChecker — catches subject-verb agreement, doubled words, capitalization, and similar issues. English only (an Apple limitation). Exits 1 if issues are found.

```bash
$ echo "He go to the store yesterday." | lingua grammar
grammar: The word ‘go’ may not agree with the rest of the sentence. [3,2]

$ echo "It happened again again." | lingua grammar --json
[{"type":"grammar","value":"again again","description":"The word ‘again’ may be inadvertently doubled.  Consider deleting the second instance.","corrections":["again"],"range":[12,11]}]
```

### Style Checking

Informal writing-style checks built on the part-of-speech tagger: passive
voice, adverb pile-ups, and overlong sentences. English only. Exits 1 if
issues are found.

```bash
$ echo "Mistakes were made by the team." | lingua style
style: passive voice: 'were made' [9,9]

$ echo "This is a test sentence that should definitely have more than twenty words in it to demonstrate the style checking feature properly." | lingua style --max-words=20
style: 3 adverbs in one sentence [0,132]
style: sentence has 22 words (max 20) [0,132]
```

### Dictionary Definitions

Look up any word or phrase in the dictionaries you have enabled in
Dictionary.app — the same lookup behind force-touch. Exits 1 when no
definition is found.

```bash
$ lingua define serendipity
serendipity ser·en·dip·i·ty | ˌserənˈdipədē | noun the occurrence and development of events by chance in a happy or beneficial way: a fortunate stroke of serendipity | a series of small serendipities. ORIGIN 1754: coined by Horace Walpole, suggested by The Three Princes of Serendip, the title of a fairy tale in which the heroes 'were always making discoveries, by accidents and sagacity, of things they were not in quest of'. ...

$ lingua define "lingua franca" --json
{"term":"lingua franca","definition":"lingua franca lin·gua fran·ca | ˌliNGɡwə ˈfraNGkə | noun (plural lingua francas | ˈliNGɡwə ˈfraNGkəz |) a language that is adopted as a common language between speakers whose native languages are different. • historical a mixture of Italian with French, Greek, Arabic, and Spanish, formerly used in the Levant. ORIGIN late 17th century: from Italian, literally 'Frankish tongue'. ..."}
```

### English LSP

`lingua lsp` (lingua 0.4.0+) runs a Language Server Protocol server over
stdio, turning any LSP-capable editor into an English grammar and spelling
checker. Spelling issues appear as errors (red squiggles) with quick fixes
from the system spell checker's suggestions; grammar issues appear as
warnings (yellow squiggles). Style findings (passive voice, adverb pile-ups, long sentences) appear as information-level hints (blue). Powered by the same `grammar`/`spell`/`style` machinery.

```bash
lingua lsp   # speaks LSP over stdin/stdout; run it from an editor, not a terminal
```

**VS Code:** a development-mode extension lives in
[`editors/vscode`](editors/vscode) — open that folder in VS Code, `npm
install && npm run compile`, press F5, and open a markdown, plain text, or
git commit file in the development host. The extension launches `lingua`
from your `PATH` by default; to use a different binary (say, a local
`zig-out/bin/lingua` build), set the `lingua.path` setting.

**Neovim** needs no plugin:

```lua
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'markdown', 'text', 'gitcommit' },
  callback = function()
    vim.lsp.start({ name = 'lingua', cmd = { 'lingua', 'lsp' } })
  end,
})
```

## Composability

lingua reads from stdin and writes to stdout, so it pipes naturally with other tools:

```bash
# Detect language of a file
cat document.txt | lingua detect

# Extract all phone numbers from a webpage
curl -s https://example.com | lingua entities --type=phone

# Analyze sentiment of each line
while read -r line; do echo "$line" | lingua sentiment; done < reviews.txt

# JSON pipeline
echo "Call 555-1234 on Tuesday" | lingua entities --json | jq '.[] | select(.type == "phone")'
```

## Commands

| Command | What it does |
|---------|-------------|
| `detect` | Identify language (58+ languages) |
| `sentiment` | Score sentiment (-1.0 to 1.0) |
| `entities` | Extract structured data (phones, emails, addresses, dates, URLs, flights) |
| `ner` | Named entity recognition (people, places, organizations) |
| `pos` | Part-of-speech tagging |
| `tokenize` | Tokenize into words, sentences, or paragraphs |
| `spell` | Check spelling (exit 1 if issues found) |
| `grammar` | Check grammar — agreement, doubled words (exit 1 if issues found) |
| `style` | Check writing style — passive voice, adverbs, sentence length (exit 1 if issues found) |
| `define` | Look up a dictionary definition (exit 1 if not found) |
| `lsp` | Run a Language Server Protocol server (diagnostics + quick fixes) |

## Options

```
Global:
  --json              Structured JSON output
  --help, -h          Show help
  --version, -v       Show version

detect:
  --top=N             Show top N language candidates (default: 1)

sentiment:
  --per-sentence      Score each sentence individually

entities:
  --type=TYPE         Filter: phone, email, address, date, url, transit, all (default: all)

tokenize:
  --unit=UNIT         word, sentence, paragraph (default: word)

grammar, spell:
  --lang=XX           Force language (default: auto-detect)

style:
  --max-words=N       Flag sentences longer than N words (default: 30)
  --max-adverbs=N     Flag sentences with N or more adverbs (default: 3)
```

## Exit Codes

`grammar`, `spell`, and `style` behave like linters: exit 0 when clean, 1 when issues are found, 2 on usage or runtime errors. `define` exits 0 when a definition is found, 1 when not, 2 on usage errors. All other commands exit 0 on success.

```bash
# Block a commit if the README has typos
cat README.md | lingua spell && git commit -m "Update docs"
```

## Requirements

- macOS 10.15+ (Catalina or later)
- Zig 0.16+

## How It Works

lingua bridges to macOS native frameworks via Objective-C runtime bindings (`objc_msgSend`). No Swift, no Xcode, no external dependencies.

- **Language detection:** [NLLanguageRecognizer](https://developer.apple.com/documentation/naturallanguage/nllanguagerecognizer)
- **Sentiment, POS, NER:** [NLTagger](https://developer.apple.com/documentation/naturallanguage/nltagger)
- **Tokenization:** [NLTokenizer](https://developer.apple.com/documentation/naturallanguage/nltokenizer)
- **Entity extraction:** [NSDataDetector](https://developer.apple.com/documentation/foundation/nsdatadetector)
- **Spelling, grammar:** [NSSpellChecker](https://developer.apple.com/documentation/appkit/nsspellchecker)
- **Definitions:** [Dictionary Services](https://developer.apple.com/documentation/coreservices/1446842-dcscopytextdefinition) (`DCSCopyTextDefinition`)

## Related Projects

- [loupe](https://github.com/georgemandis/loupe) — Computer vision CLI (Vision framework)
- [whereami](https://github.com/georgemandis/whereami) — Location CLI (CoreLocation)
- [nearme](https://github.com/georgemandis/nearme) — Local search CLI (MapKit)

## Credits

Created by [George Mandis](https://george.mand.is) during [Recurse Center](https://www.recurse.com/).
