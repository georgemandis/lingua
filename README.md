# lingua

Natural language processing from the command line, powered by native macOS APIs.

Language detection, sentiment analysis, part-of-speech tagging, named entity recognition, structured entity extraction (phone numbers, emails, addresses, dates, flight numbers), spelling and grammar checking, and tokenization — all on-device, no API keys, no downloads, no network calls.

Written in Zig. Uses Apple's NaturalLanguage framework and NSDataDetector via Objective-C runtime bindings.

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
```

## Exit Codes

`grammar` and `spell` behave like linters: exit 0 when clean, 1 when issues are found, 2 on usage or runtime errors. All other commands exit 0 on success.

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

## Related Projects

- [loupe](https://github.com/georgemandis/loupe) — Computer vision CLI (Vision framework)
- [whereami](https://github.com/georgemandis/whereami) — Location CLI (CoreLocation)
- [nearme](https://github.com/georgemandis/nearme) — Local search CLI (MapKit)

## Credits

Created by [George Mandis](https://george.mand.is) during [Recurse Center](https://www.recurse.com/).
