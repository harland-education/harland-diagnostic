# Harland Diagnostic System — Project Handover

This document hands over the Harland Education student diagnostic system to a fresh chat or new collaborator. It contains everything needed to maintain, extend, and operate the system without context from prior conversations. Read this top to bottom before doing any work.

---

## 1. Project Overview

Harland Education is a premium 1-on-1 tutoring academy based in Taipei's Xinyi district, founded by Phil. The diagnostic system is a scalable platform of single-file HTML assessments that:

1. Students complete via a public URL (served from GitHub Pages over HTTPS).
2. Responses flow into Supabase (a hosted Postgres + REST API).
3. A Head Teacher uses an admin dashboard to view results, link students, and generate AI-powered personalised reports via the Anthropic API (routed through a Cloudflare Worker to bypass CORS).
4. The Head Teacher reviews and sends the report.

The system is **maintainable by non-developers**. Diagnostics are single-file HTML, dropped into a GitHub repo, and served live.

---

## 2. Infrastructure & Credentials

### Supabase (database + REST API)
- **Project URL:** `https://takuuqvpyqvomcfmcjoz.supabase.co`
- **Anon key (safe for client-side use, embedded in every diagnostic):**
  ```
  eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRha3V1cXZweXF2b21jZm1jam96Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ2ODM2MDYsImV4cCI6MjA5MDI1OTYwNn0.X_9VXsZBO5pKlNtvP5-AL6d5LlSfjNxDSb8NZB9vO7M
  ```
- RLS is permissive — anon key has full read/write on `diagnostics`, `reports`, `students`.

### GitHub repo (live source for student-facing pages)
- **Repo:** `github.com/harland-education/harland-diagnostic`
- **Live URL pattern:** `https://harland-education.github.io/harland-diagnostic/[filename].html`
- GitHub Pages serves the repo over HTTPS. Files MUST be served over HTTPS -- opening as `file://` will break (Supabase calls, font loading, etc.).
- **Deploy method:** files are pushed via the **GitHub Contents API** using a fine-grained PAT (scope: Contents read/write on `harland-diagnostic` only). GET the file's `sha`, then PUT the base64 content with that `sha` on branch `main`. This is the working, repeatable path used throughout the recent work. Pages rebuilds in ~35-55s; poll the live URL for a distinctive marker to confirm. (Manual drag-and-drop in the GitHub web UI also works as a fallback.)

### Cloudflare Worker (Anthropic API proxy)
- **Worker URL:** `https://harland-ai.philip-e-harris1.workers.dev`
- **Account ID:** `f97cde62148919eb6ff52ce1324c8a2f`
- Routes browser → Anthropic calls. Direct browser-to-`api.anthropic.com` calls are blocked by CORS; the worker accepts the API key in the request body and forwards it with correct headers.
- Worker code is in `harland_anthropic_worker.js` (the source file in outputs).
- Anthropic billing must be funded for AI report generation to work (~$0.01-0.03 per report).

### Admin dashboard
- **Live URL:** `https://harland-education.github.io/harland-diagnostic/harland_diagnostics_admin.html`
- **Login screen** stores Supabase URL/key, Anthropic API key (`sk-ant-api03-...`), Proxy URL, and user's name to `localStorage`:
  - `hd_u` → Supabase URL
  - `hd_k` → Supabase anon key
  - `hd_ak` → Anthropic API key
  - `hd_proxy` → Cloudflare Worker URL
  - `hd_w` → user's display name

### Library page
- **Live URL:** `https://harland-education.github.io/harland-diagnostic/harland_diagnostic_library.html`
- The canonical catalogue students see. Driven by a `DIAGNOSTICS` array at the top of the file. **Manually updated** — every new diagnostic must be added to this array.

---

## 3. Supabase Schema

This Supabase project is also Harland's wider HQ/CRM database, so it holds many tables beyond the diagnostic system (families, guardians, enrolments, daily_reports, messages, esign_*, leaderboard, a separate SAT `questions` item bank, etc.). Treat those as out of scope -- integrate, never recreate. The tables below are the ones the diagnostic system reads and writes. RLS is permissive for the diagnostic flow (the anon key can read what the client needs; writes to `diagnostics`/`results`/`reports` are open). The Phase 4 reference tables (`diagnostic_items`, `rubric_bands`) are anon read-only.

The exact DDL for the Phase 4 objects is version-controlled in `schema/phase4_reporting.sql`.

### `students`
| column | type | notes |
|---|---|---|
| `id` | uuid | PK |
| `full_name` | text | |
| `grade` | text | e.g. "Grade 10" |
| `school` | text | |
| `head_teacher` | text | |
| `parent_name` | text | |
| `parent_email` | text | |
| `parent_line` | text | LINE ID for messaging |
| `notes` | text | |

### `diagnostics`
| column | type | notes |
|---|---|---|
| `id` | uuid | PK |
| `student_id` | uuid | FK to students (nullable — populated after submission via admin dashboard) |
| `student_name` | text | from the diagnostic submission |
| `diagnostic_type` | text | legacy descriptive type, e.g. `ap_physics_1_readiness` |
| `diagnostic_id` | text | **FK to `diagnostics_catalog.id` (the canonical slug). Every diagnostic file must emit this on submission.** Older/cached submissions with a null value were backfilled from `diagnostic_type`. |
| `assessment_type` | text | `diagnostic` (vs mock) |
| `diagnostic_label` | text | e.g. `AP Physics 1 Readiness` |
| `raw_responses` | jsonb | every response keyed by question id |
| `mcq_scores` | jsonb | `{qid: {chosen, answer, correct}}` for each MCQ |
| `self_ratings` | jsonb | scale responses keyed by qid |
| `preferences` | jsonb | rankings and any computed fields (e.g. `estimated_score_low`, `estimated_score_high`, `time_used_seconds` for mock-style diagnostics) |

### `reports` (one row per submission; holds all three report streams)
A single report row carries the Executive, Detailed, and Parent renderings of one submission.

| column | type | notes |
|---|---|---|
| `id` | uuid | PK |
| `diagnostic_id` | uuid | **FK to `diagnostics` -- this is the SUBMISSION uuid, NOT the catalog slug.** (Naming is unfortunate but baked in.) |
| `result_id` | uuid | FK to `results` -- the structured placement this report renders |
| `student_id` | uuid | nullable, set after linking |
| `student_name` | text | |
| `diagnostic_label` | text | |
| **Executive stream** | | |
| `ai_report` | text | **NOT NULL -- must be populated on insert.** Generated executive summary |
| `edited_report` | text | HT-edited executive summary |
| `status` | text | `pending` / `reviewed` / `sent` (the executive/report workflow) |
| `reviewed_by`, `reviewed_at`, `sent_at`, `send_notes` | | review/send metadata |
| **Detailed (teacher) stream** | | |
| `ai_detailed` | text | generated synthesis prose |
| `edited_detailed` | text | HT-edited synthesis |
| `detailed_items` | jsonb | `{items:[{id,strand,assesses,student_answer,correct,interpretation}], strand_directions:[...]}` |
| **Parent stream (bilingual, gated)** | | |
| `ai_parent` / `edited_parent` | text | parent-facing report, English |
| `ai_parent_zh` / `edited_parent_zh` | text | parent-facing report, Traditional Chinese |
| `parent_released` | bool | the release gate; the parent report is **never auto-sent** |

### `diagnostics_catalog` (Phase 1 -- the catalogue source of truth)
One row per diagnostic. `id` (a slug) is the canonical id every submission links to, and the admin/library load it as a map. **Slugs are terse and subject-based** (`ap_calculus_ab`, `math_placement`, `g6_7_math`, `ib_history`, `sat_readiness`); the two English diagnostics are the historical exception (`english_diagnostic_g8_10`, `english_diagnostic_g5_7`). When building a new diagnostic, its file's `DIAGNOSTIC_SLUG` must match its catalog `id` exactly.

### `results` (Phase 2 -- the structured placement)
The machine-readable placement computed client-side by each diagnostic's scoring engine: `recommended_level` / `recommended_course` / `recommended_tier`, `confidence`, per-strand `breakdown` (jsonb), `flags`. `status` runs `computed` -> `reviewed` -> `final`. The admin's placement panel reads and writes this, and **a generated report must agree with it** (all three streams are grounded in it). Keyed: `submission_id` -> `diagnostics`, `diagnostic_id` -> catalog slug, `student_id` -> students.

### `student_placements` (view)
Latest result per student per subject, joined to `students`. Powers the admin Placements tab.

### `diagnostic_items` (Phase 4 -- the item bank)
Per-item metadata that grounds the detailed teacher report: stem, options, keyed answer, strand, target level, passage, rubric. Keyed `<catalog slug>:<item_id>`. Anon read-only. Currently seeded for `english_diagnostic_g8_10` (29 items). DDL + columns in `schema/phase4_reporting.sql`.

### `rubric_bands` (Phase 4 -- criterion descriptors)
Level descriptors per `spine`/`subject`/`level`/`strand` that ground the report's level read against an external standard. The canonical English spine is **`common_core_ela`** (Harland level N ~ US grade N; L9/L10 ~ the Grades 9-10 band). Exam diagnostics get their own spines as they are built (`ap_*`, `aice_*`, `ib_*`); the adult/ESL track uses `cefr`. Anon read-only. Currently seeded for common_core_ela/english (12 bands). DDL in `schema/phase4_reporting.sql`.

### Submission flow (three-step insert -- critical to get right)
A fully-wired diagnostic performs a **three-step insert**:

1. POST `/rest/v1/diagnostics` with the payload, **including `diagnostic_id: <catalog slug>`** and `assessment_type: 'diagnostic'`. Use `Prefer: return=representation` to get back the new submission `id`.
2. POST `/rest/v1/results` with the computed placement (`submission_id` = step 1 id, `diagnostic_id` = catalog slug, `status: 'computed'`, the breakdown). Get back the result `id`.
3. POST `/rest/v1/reports` with `{diagnostic_id: <submission id from step 1>, result_id: <result id from step 2>, student_id: null, student_name, diagnostic_label, ai_report: 'Pending HT review', status: 'pending'}`.

`ai_report` is NOT NULL -- always include the `'Pending HT review'` placeholder or step 3 returns HTTP 400. **Never POST a flat payload directly to `/rest/v1/reports`** -- the chained ids are required, and this is the most common mistake.

> Note: the only diagnostic fully on the three-step flow today is `english_diagnostic_g8_10`. Most others still do the older **two-step** (diagnostics -> reports, no `results` emit and no item bank). Bringing them onto the three-step flow + giving each an item bank is the current rollout (Section 12).

---

## 3A. The Reporting System (Three Streams)

One submission produces ONE structured result (the `results` row). The admin renders that result three ways, for three readers, generated grounded so they never contradict each other on the facts, and stored / reviewed / released separately. In the admin report modal these are three tabs (Executive / Detailed / Parent), and the footer action bar adapts to the active tab.

Generation is client-side prompt assembly in the admin, sent to the Cloudflare Worker (which proxies to Anthropic). The model is `claude-sonnet-4-6` (one constant, `STREAM_MODEL`). The model returns JSON, parsed by a tolerant parser (`parseModelJSON`) that recovers from unescaped newlines, trailing commas, and code fences; the detailed/parent token ceilings are 8000/4000.

**1. Executive (admin-facing)** -- the internal summary. Grounded in the structured result + strand levels + the Common Core criterion ladder; its level read must agree with the placement. Plain prose, no markdown. Stored in `ai_report` / `edited_report`. The footer's Save-as-reviewed / Mark-as-sent drive its workflow.

**2. Detailed (teacher-facing)** -- a per-question walk-through. For each item: the student's actual answer, right or wrong, and what that specific answer signals (the misconception the chosen distractor implies, or the skill a correct answer confirms), plus a teaching direction per strand and a synthesis. **Grounded in `diagnostic_items`** (the real questions + keyed answers joined to the student's responses) and the criterion ladder. Density rule: full interpretation on wrong answers, a brief confirmation on correct ones. Stored in `ai_detailed` / `edited_detailed` + `detailed_items`.

**3. Parent-facing** -- bilingual (English + parent-natural Traditional Chinese), warm and constructive, with ALL internal mechanics stripped (no scores, numeric levels, tiers, confidence, distractor analysis, or comparison to other students). Follows the Harland voice rules (no em dashes, "academy" not "school", no pricing, no sign-off). Generated in one bilingual call. Stored in `ai_parent` / `edited_parent` + `ai_parent_zh` / `edited_parent_zh`. **Gated by `parent_released`** -- a deliberate review-and-release step; nothing is sent automatically, and the Chinese should be read by a fluent reviewer before release.

### Grounding inputs (where report quality comes from)
- The structured `results` row (placement, per-strand breakdown, flags).
- The diagnostic's own `preferences.level_analysis.strand_levels` (computed at submission).
- `diagnostic_items` -- the real questions + keyed answers (detailed stream only).
- `rubric_bands` -- the Common Core criterion ladder for the levels in play.

If a submission's slug is missing or mismatched, the admin falls back to identifying the item bank from the answered item ids, so the detailed report still resolves.

### Reference-first rollout
The system is built and proven on `english_diagnostic_g8_10` first. Other diagnostics get the detailed + rubric grounding only once they have their own item bank and (where they compute one) a structured result. See Section 12.

---

## 4. Tech Stack Constraints (Non-Negotiable)

These constraints exist because the code runs in many browsers, on many devices, and is maintained by non-developers. Do not change them without a strong reason.

### ES5 only — no ES6+ syntax
- ❌ no `const`, no `let` (use `var`)
- ❌ no arrow functions `=>` (use `function() {}`)
- ❌ no template literals `` ` ` `` (use `'foo' + bar + 'baz'`)
- ❌ no `async`/`await` (use `.then(...)` Promises)
- ❌ no destructuring, spread, rest, default params, classes, modules
- ✅ Plain function declarations, `var`, string concatenation, `.then()`, `for (var i = 0; ...)` loops

### Validate every file before presenting
Run these checks before handing a diagnostic to Phil:
```bash
grep -cE '\b(const|let)\b' file.html   # expect 0
grep -c '=>' file.html                  # expect 0
grep -c '`' file.html                   # expect 0
grep -cE '\b(async|await)\b' file.html  # expect 0

node -e 'var fs = require("fs"); var html = fs.readFileSync("file.html","utf8");
var m = html.match(/<script>([\s\S]*?)<\/script>/g) || [];
var js = m.map(function(s){ return s.replace(/<\/?script>/g,""); }).join("\n");
try { new Function(js); console.log("JS parses OK"); }
catch(e){ console.log("SYNTAX ERROR:", e.message); }'
```

### No literal Unicode characters in JavaScript strings
This includes Greek letters, math symbols, em-dashes, smart quotes, accented Latin characters, etc. They cause inconsistent rendering and encoding issues across browsers.

Use instead:
- `--` instead of `—` (em-dash)
- `->` instead of `→` (arrow)
- `pi` instead of `π`
- `sqrt(x)` instead of `√x`
- `degrees` written out instead of `°`
- `x^2` instead of `x²` (or use HTML entities `<sup>2</sup>` in HTML markup, but never raw `²` in JS string literals)

**HTML entities are fine** in question text and option text **if you bypass `escHtml` for those fields**. The Pre-IB Diploma diagnostic uses this pattern for math notation (`<sup>2</sup>`, `&minus;`, `&radic;`). When doing so, ensure the author (you) controls every string — never use this with user input.

### Single-file standalone HTML
- Embedded `<style>` (no external CSS)
- Embedded `<script>` (no external JS)
- Two CDN dependencies allowed: Google Fonts and Anthropic API (via the worker)
- No frameworks, no build tools, no bundlers

### Brand colours and typography
- Navy: `#1B2A4A` (primary)
- Gold: `#C9A84C` (accent)
- Cream: `#F7F5F0` (background)
- Fonts: `Libre Baskerville` (serif, headings + question text), `DM Sans` (sans, body + UI)

---

## 5. The Two Diagnostic Patterns

### Pattern A — Readiness diagnostic (the standard)
- Used for: AP, IB, AICE, SSAT, ISEE, Pre-IB, debating, English placement.
- Structure: Welcome screen with name input → questions screen (all questions on one page, grouped by domain) → thank-you screen.
- No timer.
- Progress bar at top showing answered/total required.
- ~20-23 questions: a mix of MCQ, open-text, scale (1-5), and ranking.
- Templates: any of the recent files like `harland_ap_calculus_ab_diagnostic.html`, `harland_ap_physics_1_diagnostic.html`.

### Pattern B — Mock / score-prediction diagnostic
- Used for: AMC 10, AICE GP Paper 2 mock template.
- Structure: Exam-style cover with metadata → questions screen with sticky timer at top → results screen with score + breakdown + solutions.
- **Timer** matching real test pace (e.g. 45 min for AMC 10, 45 min for GP Paper 2).
- Auto-scored where possible; reveal solutions after submit (gated).
- Templates: `harland_amc10_diagnostic.html`, `harland_mock_aice_gp_paper2.html`.
- Mocks will eventually have their own library page (separate from readiness diagnostics). Not yet implemented.

---

## 6. Critical Recurring Patterns

These are the gotchas that have caused real bugs in this project. Follow all of them on every new diagnostic.

### 1. `ai_report` NOT NULL constraint
Every report insert payload MUST include `ai_report: 'Pending HT review'`. Omitting it returns HTTP 400.

### 2. `STUDENT_ID = null` on submission
Diagnostics submit with `student_id: null`. The HT links the diagnostic to a student record after submission via the admin dashboard's "Link student" button (which either picks an existing student or creates a new one).

**Never** hardcode `STUDENT_ID` per-file. **Never** ask the student for their UUID. Always `null`.

### 3. MCQ answer position must be evenly distributed
The biggest historical failure mode: students gaming the diagnostic by always picking the same letter. If all answers cluster at B, a student picking "always B" gets ~100% with no real assessment.

Distribute correct answers approximately evenly across A/B/C/D (or A-E for 5-option). For 14 MCQ targeting 4-option: aim for ~3-4 each. For 15 MCQ with 5 options: aim for 3 each.

Verify before presenting:
```bash
grep -oE "answer: [0-4]" file.html | sort | uniq -c
```

A 7-1-3-3 distribution is unacceptable. Re-shuffle distractors to redistribute.

### 4. CORS workaround for Anthropic API
Direct browser-to-`api.anthropic.com` calls from GitHub Pages are blocked by CORS. The Cloudflare Worker accepts the API key in the request body and forwards it to Anthropic with proper headers. The admin dashboard sends to the proxy URL, not directly to Anthropic.

### 5. Source-block rendering for primary sources
For diagnostics with reading passages (IB History, AICE GP, Pre-IB English analysis), questions support optional fields:
- `source`: the passage text (HTML allowed)
- `sourceAttr`: attribution under the source
- `textAfter`: prompts/instructions after the passage

The Pre-IB Diploma diagnostic is the cleanest current reference for source-block rendering.

### 6. Open-text `minLength: 1`
For required open-text questions, set `minLength: 1` (not a higher number). The HT judges quality, not character count. Higher thresholds cause students to add filler.

---

## 7. Standard Workflow for a New Diagnostic

Phil's established working pattern:

1. **Phil requests a diagnostic** (e.g. "Make me an SAT readiness diagnostic")
2. **Claude asks 2-3 clarifying questions** via the `ask_user_input_v0` tool: usually scope/level, target grade, purpose
3. **Claude builds the diagnostic** using the readiness or mock template:
   - Full ES5 architecture
   - Supabase wired with the three-step insert (diagnostics -> results -> reports), emitting the catalog slug
   - `ai_report: 'Pending HT review'` baked in
   - Brand colours and fonts
   - MCQ answer distribution evenly spread
   - All math verified by hand
4. **Claude validates** before presenting:
   - ES5 grep checks
   - Answer distribution check
   - JS syntax check via `new Function(...)`
5. **Claude presents the file** via `present_files`
6. **Phil reviews and may request a consultation pass** (see Section 8)
7. **Push to GitHub** via the Contents API + fine-grained PAT (GET sha -> PUT base64 content on `main`); Pages rebuilds in under a minute. Manual drag-and-drop in the web UI is a fallback.
8. **Add the entry to the library** (`harland_diagnostic_library.html`) — append a new entry to the `DIAGNOSTICS` array under the appropriate category

---

## 8. Consultation Pass Methodology

Phil routinely asks for a "consultation pass" after the first build. This is **not a light proofread** — it's a substantive review with real fixes.

What to check, in order:

1. **Verify the math/factual content from scratch.** Don't trust your own first pass. Work every MCQ problem on paper. The AMC 10 had been built once and the pass caught two too-easy questions plus a wording issue. The AP Calc AB had been built once and the pass caught two weak distractor sets.
2. **Check distractor quality.** Every wrong option should map to a specific student misconception. If a distractor has no clean error path (e.g. "7" with no reason a student would arrive at 7), replace it with a value that does.
3. **Check answer distribution.** Re-run the grep. If imbalanced, plan a shuffle.
4. **Check for duplicate concepts.** Two questions testing the same skill is a waste.
5. **Check difficulty calibration.** For score-prediction diagnostics (AMC), "easy" questions must actually be at AMC Q1-Q10 level — not middle-school level. For readiness diagnostics, the band depends on the grade target.
6. **Check wording for ambiguity.** Questions like "using each of the digits 2, 0, 2, 4 exactly once" are technically correct but stylistically clunky given the duplicate 2.
7. **Surface findings honestly, then fix.** Don't just list issues — apply the fixes. Phil expects working improvements.

After fixes, re-run all validation checks. Present with a clear summary of what changed and why.

---

## 9. Common Pitfalls (Lessons from This Project)

- **Don't post a flat payload directly to `/rest/v1/reports`.** The three-step insert (with chained `submission_id` and `result_id`) is mandatory for fully-wired diagnostics.
- **Don't omit `ai_report`** in the report insert. Will return HTTP 400.
- **Don't put unicode characters in JS string literals.** Use ASCII equivalents or HTML entities (in HTML markup only).
- **Don't cluster correct answers at one position.** Students will game.
- **Don't write distractors with no error path.** They give no diagnostic signal.
- **Don't use `const`/`let`/arrow/template literal/async**. ES5 only.
- **Don't open the diagnostic as `file://`** — Supabase and font loading require HTTPS.
- **GitHub deploys go through the Contents API with a fine-grained PAT** (Contents read/write on `harland-diagnostic`). This is the working path. Browser automation of the GitHub *web UI* was the thing that failed historically -- avoid that, but the API push is reliable. There is no GitHub MCP connector; the PAT + Contents API (or manual drag-and-drop) are the routes.

---

## 10. Current State of the System (as of June 2026)

### Reporting system (Phase 4 -- the major recent work)
The admin generates **three grounded report streams** per submission (Executive / Detailed / Parent), backed by a structured `results` placement, an item bank (`diagnostic_items`), and a Common Core criterion ladder (`rubric_bands`). See Section 3A. Built and proven end-to-end on `english_diagnostic_g8_10`; the rollout to other diagnostics is the current work (Section 12). The Phase 4 DDL is captured in `schema/phase4_reporting.sql`.

### Database evolution since the first build
- **Phase 1:** `diagnostics_catalog` -- the catalogue source of truth (terse slugs).
- **Phase 2:** `results` + `student_placements` view -- the structured placement.
- **Phase 4:** `diagnostic_items` + `rubric_bands` + the three stream columns on `reports`.
- The two math diagnostics now emit their canonical catalog slug; all historical submissions backfilled (zero null slugs).

### Live diagnostics in the library (13 total)
1. **AP** (5): Science, Economics, Computer Science A, Physics 1, Calculus AB
2. **IB** (2): Pre-IB Diploma Readiness, IB History
3. **AICE** (2): General Paper, European History
4. **Math Competition** (1): AMC 10 (score-prediction)
5. **Test Prep** (2): SSAT Upper Level, ISEE Lower Level
6. **General** (1): High School Debating

Plus the English and Math placement diagnostics (`english_diagnostic_g8_10`, `english_diagnostic_g5_7`, `math_placement`, `g6_7_math`).

### Planned diagnostics (in the library as cards but not built)
- SAT Readiness
- Academic English Placement
- WIDA English Proficiency

### Tools & infrastructure files
- `harland_diagnostic_library.html` — public catalogue
- `harland_diagnostics_admin.html` — admin dashboard with AI report generation
- `harland_diagnostic_builder.html` — visual builder for non-developers (NOT yet uploaded to GitHub)
- `harland_diagnostic_template.html` — reusable template (reference only)
- `harland_anthropic_worker.js` — Cloudflare Worker proxy source
- `harland_mock_aice_gp_paper2.html` — exam-authentic mock template (first of a future mock library)

---

## 11. Admin Dashboard Usage

1. Open `https://harland-education.github.io/harland-diagnostic/harland_diagnostics_admin.html`.
2. On first use, log in by entering the Supabase URL, anon key, Anthropic API key, proxy URL, and your name. These save to `localStorage`.
3. Dashboard shows recent diagnostics with status pills (pending / reviewed / sent).
4. Click a diagnostic to see all responses.
5. Click "Link student" to associate the diagnostic with a student record (pick existing or create new — this populates `student_id` after the fact).
6. Click "Generate AI report" to produce a personalised report via the Anthropic API. Edit, then mark as reviewed.
7. Mark as sent when the parent communication has gone out.

The Anthropic API call is sent to the Cloudflare Worker proxy with the API key in the request body. Cost: ~$0.01-0.03 per report.

---

## 12. Pending Action Items

The current priority:

- **Roll the item banks and result-emit out to the other diagnostics.** This is the active work. The reference implementation is `english_diagnostic_g8_10`, which is the only diagnostic fully on the three-step flow with an item bank. Each other diagnostic needs: (a) its own item bank extracted into `diagnostic_items` (parse its `QUESTIONS` array the way the English one was done -- store passages once per section, resolve keyed answers, exclude profile/scale items), (b) a `buildResult`/results-emit mapping so it moves from the two-step to the three-step flow, and (c) where applicable its own `rubric_bands` spine (AP standards for AP, AICE for AICE, IB for IB, Common Core for the canonical English/math ladders).

Independent items:

- **Move the Anthropic key server-side** into the Worker (hold it as a Cloudflare secret and redeploy; the admin stops sending `_apiKey`). Currently the key is entered client-side and kept in `localStorage`.
- **Brand-restyle the remaining surfaces** -- the ~13 other diagnostics, the builder, and the template have not been put through the current Harland aesthetic.
- **Run all three streams end-to-end on real students** to confirm output before scaling the pattern out.

Older backlog (still open, lower priority):
- Build the SAT Readiness, Academic English Placement, and WIDA English Proficiency diagnostics (in the library as 'planned').
- Upload the diagnostic builder (`harland_diagnostic_builder.html`) to GitHub if Phil wants it live.
- Audit older diagnostics for answer-position distribution.

---

## 13. Files to Hand Over with This Document

The next chat should be given:
- This handover document (`HARLAND_HANDOVER.md`)
- All 14 currently-live HTML diagnostic files
- The library file
- The admin dashboard file
- The Cloudflare Worker source
- The mock template
- The diagnostic builder (if Phil wants it carried forward)

See the "files surfaced in this chat" section that accompanies this handover.

---

## 14. How to Start a New Chat From This Document

A new Claude chat reading this for the first time should:

1. Read this entire document.
2. Confirm to Phil that they understand the system before making changes.
3. When asked to build a new diagnostic, follow the standard workflow (Section 7).
4. When asked to do a consultation pass, follow the methodology (Section 8).
5. When uncertain about a constraint, default to the stricter interpretation (e.g. if unsure whether a character is ASCII, use the safe ASCII alternative).
6. Validate every file with the bash checks before presenting.
7. Never invent infrastructure — the URLs and keys in Section 2 are authoritative.

---

*End of handover document.*
