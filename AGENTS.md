# Mochi project instructions

Mochi is a macOS voice conversation app. Work in this repository as `cto`.

## Communication and decisions

- Respond in Plain English, address the user as Hui, and explain uncommon technical terms.
- For consequential decisions, selectively offer: `Let Qwen weigh in — deliberate, then recommend.`
- When Hui accepts, consult Qwen through `cc-suite` without another confirmation, evaluate its reasoning independently, and give a synthesized recommendation. If Qwen is unreachable, say so and proceed.

## Automatic commit, push, and deployment

After every completed change or upgrade, automatically commit, push, and deploy. Hui has authorized this workflow for this project; complete these steps without asking for routine confirmation again.

1. Check the changes and run the tests for the changed code. Preserve unrelated work and stage only the files belonging to the completed task. Keep credentials, user conversations, local audit records, build outputs, and rollback copies outside commits.
2. Commit the verified changes, then push the current working branch to `origin`, Hui's fork at `https://github.com/linhui0813-byte/mochi-macOS.git`. Verify that the remote branch contains the local commit. Keep `upstream` pointing to `https://github.com/xiaolai/mochi-macOS.git`.
3. Deploy the committed app code to `/Applications/Mochi.app` on Hui's Mac. Build to a new output path, fully quit Mochi using **Quit Mochi Completely**, preserve the installed app as a verified rollback copy, install the build, and relaunch it. Verify the installed file hashes, code signature, and running executable. If the exact app code is already deployed and verified, record that existing deployment against the new commit; a documentation-only change does not require replacing an identical app.
4. Report the commit, pushed branch, test results, and verified deployment. If tests, push, or deployment fail, fix the failure or report the concrete blocker and completed steps. Distinguish automated checks from live microphone and speaker checks.

## Build and test

- Build: `MOCHI_APP_PATH=<new-output-path>/Mochi.app bash scripts/build-app.sh`.
- Tests: `swift test` and `python3 -m unittest discover -s scripts/tests`.
- Run the installed app at `/Applications/Mochi.app`. Use a separate test Mac for the native smoke-test and single-instance test modes described in `README.md`; they register test app copies with Launch Services.

## Project structure

Use `Sources/MochiApp` for the macOS UI and audio session lifecycle, `MochiCore` and `MochiKernel` for models and shared logic, and `MochiProviders` for service connections. `MochiAutomation` and `MochiMCP` provide external control. Regression tests live in `Tests`; build and release tooling lives in `scripts`.
