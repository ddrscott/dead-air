// afm: Apple's on-device language model as a filter. The prompt comes from the
// arguments, or from stdin when there are none; the reply goes to stdout.
import Foundation
import FoundationModels

let usage = """
usage: afm [-i instructions] [-t temperature] [-n max-tokens] [-s] [prompt ...]

Sends the prompt to Apple Intelligence's on-device model and prints the reply.
With no prompt arguments, the prompt is read from stdin.

  -i, --instructions TEXT   system instructions (or @file to read them from a file)
  -t, --temperature N       sampling temperature, 0 to 2
  -n, --max-tokens N        cap the length of the reply
  -s, --stream              print the reply as it's written
      --check               say whether the model is available and exit

exit status: 0 ok, 1 generation failed, 2 bad usage, 3 context too long,
             4 refused by Apple's guardrails, 69 model unavailable
"""

func fail(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("afm: \(msg)\n".utf8))
    exit(code)
}

var instructions: String?
var temperature: Double?
var maxTokens: Int?
var stream = false
var check = false
var words: [String] = []

var args = CommandLine.arguments.dropFirst().makeIterator()
func value(_ flag: String) -> String {
    guard let v = args.next() else { fail("\(flag) needs a value", 2) }
    return v
}
while let a = args.next() {
    switch a {
    case "-i", "--instructions": instructions = value(a)
    case "-t", "--temperature":
        guard let t = Double(value(a)) else { fail("\(a) wants a number", 2) }
        temperature = t
    case "-n", "--max-tokens":
        guard let n = Int(value(a)) else { fail("\(a) wants a whole number", 2) }
        maxTokens = n
    case "-s", "--stream": stream = true
    case "--check": check = true
    case "-h", "--help": print(usage); exit(0)
    case "--": while let w = args.next() { words.append(w) }
    default:
        if a.hasPrefix("-") && a.count > 1 { fail("unknown option \(a)\n\n\(usage)", 2) }
        words.append(a)
    }
}

let model = SystemLanguageModel.default
switch model.availability {
case .available:
    if check { print("available"); exit(0) }
case .unavailable(let why):
    fail("model unavailable: \(why)", 69)
}

if let i = instructions, i.hasPrefix("@") {
    guard let text = try? String(contentsOfFile: String(i.dropFirst()), encoding: .utf8) else {
        fail("can't read \(i.dropFirst())", 2)
    }
    instructions = text
}

var prompt = words.joined(separator: " ")
if prompt.isEmpty {
    prompt = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}
prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
if prompt.isEmpty { fail("empty prompt\n\n\(usage)", 2) }

let session = instructions.map { LanguageModelSession(instructions: $0) } ?? LanguageModelSession()
let options = GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)

do {
    if stream {
        var printed = ""
        for try await snap in session.streamResponse(to: prompt, options: options) {
            let text = snap.content
            if text.hasPrefix(printed) {
                FileHandle.standardOutput.write(Data(text.dropFirst(printed.count).utf8))
            } else {
                FileHandle.standardOutput.write(Data(("\n" + text).utf8))
            }
            printed = text
        }
        print()
    } else {
        print(try await session.respond(to: prompt, options: options).content)
    }
} catch let e as LanguageModelSession.GenerationError {
    switch e {
    case .exceededContextWindowSize: fail("prompt is too long for the on-device model (4,096 tokens)", 3)
    case .guardrailViolation, .refusal: fail("refused: \(e.localizedDescription)", 4)
    default: fail("\(e)", 1)
    }
} catch {
    fail("\(error)", 1)
}
