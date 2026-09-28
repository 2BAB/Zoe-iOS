# Zoe

A small sample that uses simple cloud–device coordination to provide low-cost web content subscriptions in simple scenarios.

A cloud model builds and tests a workflow. After you save it, later runs use WebKit and Apple Foundation Models on the device, reducing repeated cloud-model calls.

## Requirements

- Xcode 27 and iOS 27 / macOS 27.
- An Apple Intelligence-capable device with Apple Intelligence enabled and the local model ready.
- A Gemini API key or Apple's Private Cloud Compute entitlement to build new workflows. Bundled samples can run without a cloud API key.

## Run

1. Open `Zoe.xcodeproj`, select the Zoe scheme and choose **My Mac**. For iPhone or iPad, configure your signing team and bundle identifier.
2. Wait for the model status to show **ready**.
3. Choose a sample, review it, select **Save Workflow**, then **Run on Device**.

The bundled samples were generated and tested by the cloud builder:

- **Hacker News:** Apple-related stories and sentiment in their first three top-level comments.
- **Swift Evolution:** Active Review proposals filtered and classified by topic.
- **arXiv:** Recent cs.AI papers selected by topic and summarized from their abstracts.

Saved workflows can also run through Shortcuts. Background and locked-device execution are experimental.

To create a workflow, enter a start URL and a short goal, choose a builder, and select **Build Workflow**. For Gemini, paste your API key into the app or set `GEMINI_API_KEY`; the key stays in memory. Review the generated workflow before saving.

## How it works

The cloud builder inspects pages, writes JavaScript and short local-model instructions, and tests the workflow. During replay, Swift coordinates page navigation and model calls; JavaScript handles page interaction and extraction.

The local model selects, classifies or summarizes small inputs using independent sessions. Replay limits input to 2K tokens and the total context budget to 4K; selection uses batches of up to ten records. Results retain source links, and skipped items appear in the run log.

Workflows and the latest results are stored locally.

## Code

- [WorkflowBuilder.swift](Zoe/Builder/WorkflowBuilder.swift): cloud model and building tools.
- [OnDeviceModel.swift](Zoe/LanguageModels/OnDeviceModel.swift): local profile, structured output and token budgets.
- [WorkflowRunner.swift](Zoe/Workflow/WorkflowRunner.swift): browser and model coordination.

## Tests

Unit and WebKit fixture tests cover execution and data contracts:

```sh
xcodebuild test -project Zoe.xcodeproj -scheme Zoe \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/zoe-tests CODE_SIGNING_ALLOWED=NO
```

Real-model checks require an Apple Silicon Mac with the Core model ready. They use synthetic inputs and offline pages; inspect the reported scores rather than treating completion as an accuracy guarantee.

```sh
zsh Tools/smoke.sh model /private/tmp/zoe-core-check
zsh Tools/smoke.sh run-offline-hn Zoe/Resources/hn-ai-watch.json /private/tmp/zoe-hn-offline-check
```

Run one smoke command at a time. Results and logs are saved in the chosen directory.

## Scope and privacy

Simple public list and detail pages are the intended scope. Logins, CAPTCHAs and complex interactions may fail; website changes may require rebuilding. Automatic scheduling and model accuracy need further validation.

Before running a workflow, check and respect the site's `robots.txt` and automation policy. Do not crawl disallowed pages or bypass access restrictions.

Building sends page observations to the chosen cloud model. Replay processes content locally, while websites receive normal browsing requests. Generated scripts can have side effects, and the host allowlist covers document navigation rather than all network activity. Review workflows and follow each site's automation policy. See [PRIVACY.md](PRIVACY.md).

## Foundation Models reference

Apple Foundation Models dynamically determine the on-device model variant and context window based on hardware tier:

| Variant | Architecture | Context window | Reasoning level | Hardware tier |
| :--- | :--- | :--- | :--- | :--- |
| `.core3` (Core) | 3B dense | 4K tokens (4,096) | Standard / `.light` | iPhone 15 Pro, iPhone 16 series, M1 / M2 Macs |
| `.coreAdvanced3` (Core Advanced) | 20B sparse (1–4B active) | 8K tokens (8,192) | Supports `.deep` | iPhone 17 Pro, iPhone Air, M4 iPads (≥12 GB), M3+ Macs (≥12 GB) |
| PCC (Private Cloud Compute) | Server-grade foundation model | 32K tokens (32,768) | Full reasoning | Cloud-hosted; requires developer entitlement |

Zoe targets the `.core3` baseline (3B dense / 4K context) for its replay token budgeting and batch packing limits. This ensures workflows remain fully operable across the entire Apple Intelligence device fleet without assuming high-tier hardware.

## References

Apple's [Origami](https://developer.apple.com/documentation/foundationmodels/origami-crafting-a-dynamic-tutorial-for-apple-intelligence) and [Book Tracker](https://developer.apple.com/documentation/evaluations/book-tracker-using-evaluations-to-evaluate-an-intelligent-feature) samples.

## License

Apache License 2.0. See [LICENSE](LICENSE).
