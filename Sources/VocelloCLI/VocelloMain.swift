import Foundation

/// `vocello` — headless Vocello TTS over the in-process MLX engine.
/// User-facing generation without the UI + the deterministic benchmark/test driver.
@main
@MainActor
enum VocelloMain {
    static func main() async {
        var argv = Array(CommandLine.arguments.dropFirst())
        guard let sub = argv.first else { printUsage(); exit(2) }
        argv.removeFirst()

        do {
            switch sub {
            case "generate", "gen":
                try await GenerateCommand.run(argv)
            case "voices", "voice":
                try await VoicesCommand.run(argv)
            case "bench", "benchmark":
                try await BenchCommand.run(argv)
            case "help", "-h", "--help":
                printUsage()
            case "version", "--version", "-v":
                print("vocello \(vocelloCLIVersion)")
            default:
                FileHandle.standardError.write(Data("unknown command: \(sub)\n\n".utf8))
                printUsage()
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        vocello — headless Vocello TTS (Qwen3-TTS via MLX)

        Commands:
          generate   synthesize a clip            (vocello generate --help)
          voices     manage saved clone voices    (vocello voices help)
          bench      drive the perf/quality matrix (vocello bench --help)
          help       show this message
          version    print version

        The `review` command (agy audio review) arrives in the next phase.
        """)
    }
}
