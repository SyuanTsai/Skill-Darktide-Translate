<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->
# SYP-88 Real MOD End-to-End Trial

## Trial

- Date: 2026-08-22 (Asia/Taipei)
- MOD: Reconnect, Nexus 132, version 1.3.0
- Source archive: `Reconnect 132 1.3.0 2026-08-18T02-33Z UszQnsmqf.zip`
- Archive size: 5,413 bytes
- Archive SHA-256: `ce8528da60ed66cb031ac5c4531198d56056d03c649831ef05c99a955b379adb`
- Public source facts: [Reconnect](https://www.nexusmods.com/warhammer40kdarktide/mods/132), last updated 18 August 2026 at 2:33AM, main file uploaded at the same time.
- Trial PR: [Warhammer-40-000-DARKTIDE-Mods #104](https://github.com/SyuanTsai/Warhammer-40-000-DARKTIDE-Mods/pull/104)

The trial used a real queue archive and the target repository's current `origin/main`. It reached `awaiting-user-merge`; the automation did not merge the PR or release the MOD reservation.

## Evidence chain

| Boundary | Commit OID | Tree OID |
| --- | --- | --- |
| C0 | `b884bc15ea5ba1cfc64e6a425c9490b835b58604` | `591f61bd958c8dab84f726b7d9e6b7201c17818a` |
| C1 | `3cde891cbc4dd105a878244c8ef2b1c7d02958e9` | `2bbf70c76656630bd925f9b7100dc9e115a08c0c` |
| C2 | `28d33999fba97c4d8a24a1729bc590fc47706980` | `5b6c8dc478cd97edf52abc824fbb55ad8575faf8` |
| C3 | `06f749bb2aee71d1596cfb6431e6e86d46c21190` | `34dc100c1787dee669e62910cc2496d20af8cf13` |
| F | `41b9828ec71b66ec2630540b9474188a78b26491` | `b46094ecfc6b0aad308a8a88d804e26c17d6d0ac` |

C1 contains only the three non-localization upstream paths. C1..C2 shows the new `show_system_menu_button` localization unit and upstream localization changes. C2..C3 contains seven approved `zh-tw` byte-span restorations. C3..F contains only `README.md` and `.hash/reconnect.hash`.

## Timings

The wall-clock interval from claim start to `awaiting-user-merge` was approximately 9 minutes 18 seconds, including Agent source verification, localization decisions, metadata preparation, local Review, and external Review disposition.

| Stage | Attempt | Active milliseconds | Waiting milliseconds |
| --- | ---: | ---: | ---: |
| claim | 1 | 10,891 | 0 |
| verify-source | 1 | 92 | 0 |
| extract | 1 | 69 | 0 |
| install | 1 | 481 | 0 |
| localization | 1 | 255 | 0 |
| build-commits | 1 | 1,857 | 0 |
| validate | 2 | 1,424 | 0 |
| publish | 2 | 7,946 | 0 |
| review-snapshot | 1 | 5,925 | 0 |

The second validation attempt added the independent diff-readability artifact without changing F. The second publication attempt updated the existing PR evidence body after that Gate SHA changed; it reused the branch and PR and did not create duplicates.

## Final Gates

- Extraction manifest SHA-256: `7698186f763e733329a6ef81c7a28c80c228733b615eeefdcdd3e989ce19f3cb`
- Raw-install manifest SHA-256: `1bb7b2a14e5b1d44f09a19154a0b39d131c72a4d6283f821c58bf8c57f09aa14`
- Install manifest SHA-256: `38a9cd15b02148cbec1efeb0c76d697bf632d2941e38aaf7f7d074a7e9ccd3c5`
- Candidate-tree manifest SHA-256: `0b8f7056ce4d60ea1cccf7919b9b1eb9f58363d2ce807cfdd3369e4aafdf9c20`
- Git-index normalization SHA-256: `7191344f54b8d18b8767146f58096be3aa0baadd45e72fa2cf6dfcf943621f9d`
- Evidence receipt SHA-256: `d991421dd8676bfa89662657b11d14cf8959258dfd43bcac8abe6bb21d7afb4a`
- Final validation report SHA-256: `824b667f85df3eee48593d33c2a9272c9a1c1c1570a3cd1979847ca62051d715`
- Local Review: passed with no actionable findings.
- Copilot Review: completed for F with zero inline comments. Its request for human runtime confirmation of non-localization networking behavior was classified `out-of-scope` under the packaged Review Baseline.
- External Review polling wait: 0; no watcher or periodic polling was scheduled.

This trial belongs only to the independently installed Darktide Skill. It does not add SYP-88 or SYP-92 to the AI-Instructions Catalog, Lock, bootstrap, or fan-out.
