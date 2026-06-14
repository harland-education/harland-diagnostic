-- ============================================================================
-- Harland Diagnostic System -- Phase 4 reporting schema (and Phase 1-3 additions)
-- ----------------------------------------------------------------------------
-- This file is a version-controlled RECORD of the database objects that back the
-- three-stream reporting system. It is the exact DDL as applied to Supabase
-- project takuuqvpyqvomcfmcjoz. It is idempotent (IF NOT EXISTS / OR REPLACE)
-- and safe to re-run. Seed DATA is not included here; see the notes at the end.
--
-- Tables in this file:
--   diagnostic_items   -- Phase 4: the item bank (grounds the detailed report)
--   rubric_bands       -- Phase 4: criterion descriptors (grounds the level read)
--   reports (columns)  -- Phase 4: the three report-stream columns
--
-- Phases 1-3 objects (diagnostics_catalog, results, student_placements) and the
-- reports table itself are documented in HARLAND_HANDOVER.md section 3; their
-- DDL is not reproduced here because they predate this file.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- diagnostic_items -- per-item metadata that grounds the detailed teacher report.
-- One row per question per diagnostic. id = '<catalog slug>:<item_id>'.
-- distractor_logic is reserved for later, HT-reviewed authoring (currently null).
-- ----------------------------------------------------------------------------
create table if not exists public.diagnostic_items (
  id               text primary key,                                  -- '<diagnostic_id>:<item_id>'
  diagnostic_id    text not null references public.diagnostics_catalog(id),
  item_id          text not null,                                     -- e.g. 'r7_tone'
  item_order       int,
  section          text,                                             -- e.g. 'Reading: Passage Two'
  strand           text,                                             -- Reading | Grammar | Vocabulary | Writing
  assesses         text,                                             -- the skill/topic the item targets
  target_level     int,                                              -- the level the item is pitched at (mcq)
  format           text not null default 'mcq',                      -- 'mcq' | 'text'
  passage          text,                                             -- shared reading passage (stored once per section)
  stem             text not null,                                    -- the question
  options          jsonb,                                            -- ["A text","B text",...] (mcq)
  correct_index    int,                                              -- 0-based index of the key (mcq)
  correct_answer   text,                                             -- the correct option text (mcq)
  rubric           text,                                             -- for open/writing items: what mastery shows
  distractor_logic jsonb,                                            -- per-option "what this wrong choice signals" (authored later)
  notes            text,
  created_at       timestamptz not null default now(),
  unique (diagnostic_id, item_id)
);

alter table public.diagnostic_items enable row level security;

drop policy if exists "diagnostic_items public read" on public.diagnostic_items;
create policy "diagnostic_items public read" on public.diagnostic_items
  for select to anon, authenticated using (true);

create index if not exists idx_diag_items_diag   on public.diagnostic_items(diagnostic_id);
create index if not exists idx_diag_items_strand on public.diagnostic_items(diagnostic_id, strand);

comment on table public.diagnostic_items is
  'Item bank for diagnostics: per-item metadata (stem, options, keyed answer, strand, target level, passage, rubric) used to ground the detailed teacher report. distractor_logic is authored later, HT-reviewed.';


-- ----------------------------------------------------------------------------
-- rubric_bands -- criterion descriptors per spine/subject/level/strand.
-- Grounds the report's level read against an external standard.
-- Canonical English spine = 'common_core_ela' (Harland level N ~ US grade N;
-- L9/L10 ~ the Grades 9-10 band). Exam diagnostics get their own spines later
-- ('ap_*', 'aice_*', 'ib_*'); the adult/ESL track uses 'cefr'.
-- ----------------------------------------------------------------------------
create table if not exists public.rubric_bands (
  id              text primary key,                                  -- '<spine>:<subject>:<level>:<strand>'
  spine           text not null,                                     -- e.g. 'common_core_ela'
  subject         text not null,                                     -- e.g. 'english'
  level           int,                                               -- Harland level (8, 9, 10)
  grade_band      text,                                              -- e.g. 'Grade 8', 'Grades 9-10'
  strand          text not null,                                     -- Reading | Grammar | Vocabulary | Writing
  cc_strand       text,                                              -- the Common Core strand it maps to
  descriptor      text not null,                                     -- the level competency descriptor (standard + Harland content)
  anchors         jsonb,                                             -- standard codes, e.g. ["RL.8.1","RI.8.2"]
  harland_content text,                                              -- the Harland level's content focus for this strand
  created_at      timestamptz not null default now(),
  unique (spine, subject, level, strand)
);

alter table public.rubric_bands enable row level security;

drop policy if exists "rubric_bands public read" on public.rubric_bands;
create policy "rubric_bands public read" on public.rubric_bands
  for select to anon, authenticated using (true);

create index if not exists idx_rubric_bands_lookup on public.rubric_bands(spine, subject, level);

comment on table public.rubric_bands is
  'Criterion descriptors per spine/subject/level/strand used to ground reports. Canonical English spine is common_core_ela (Harland level N ~ US grade N; L9/L10 ~ Grades 9-10 band). Exam diagnostics carry their own spines (ap_*, aice_*, ib_*); adult track uses cefr.';


-- ----------------------------------------------------------------------------
-- reports -- the three report-stream columns.
-- The reports table predates Phase 4; these columns were added to it.
--   Executive stream : ai_report / edited_report (pre-existing) + status workflow
--   Detailed stream  : ai_detailed / edited_detailed / detailed_items
--   Parent stream    : ai_parent / edited_parent (+ _zh) / parent_released
-- ----------------------------------------------------------------------------
alter table public.reports
  add column if not exists result_id        uuid,          -- FK to results (the structured placement this report renders)
  add column if not exists ai_detailed      text,          -- detailed teacher report: generated prose synthesis
  add column if not exists edited_detailed  text,          -- detailed teacher report: HT-edited synthesis
  add column if not exists detailed_items   jsonb,         -- detailed teacher report: {items:[...], strand_directions:[...]}
  add column if not exists ai_parent        text,          -- parent-facing report (English): generated
  add column if not exists edited_parent    text,          -- parent-facing report (English): HT-edited
  add column if not exists ai_parent_zh     text,          -- parent-facing report (Traditional Chinese): generated
  add column if not exists edited_parent_zh text,          -- parent-facing report (Traditional Chinese): HT-edited
  add column if not exists parent_released  boolean default false;  -- the release gate; parent report is never auto-sent

comment on column public.reports.detailed_items is
  'Structured per-question record for the detailed teacher report: {items:[{id,strand,assesses,student_answer,correct,interpretation}], strand_directions:[{strand,direction}]}. The prose synthesis lives in ai_detailed/edited_detailed.';
comment on column public.reports.ai_parent_zh is
  'Traditional Chinese (Taiwan) parent-facing report, generated alongside the English ai_parent. Released together via parent_released.';


-- ============================================================================
-- SEED DATA (not run by this file; recorded here for reference)
-- ----------------------------------------------------------------------------
-- diagnostic_items : 29 rows for diagnostic_id='english_diagnostic_g8_10'
--                    (10 Reading incl. 2 passage anchors, 9 Grammar, 9 Vocabulary,
--                     1 Writing with a rubric). Extracted from the diagnostic's
--                     QUESTIONS array; profile (scale/ranking) items excluded.
--
-- rubric_bands     : 12 rows for spine='common_core_ela', subject='english'
--                    (levels 8, 9, 10 x strands Reading, Grammar, Vocabulary, Writing).
--
-- To re-seed, re-run the extraction/authoring scripts against the live diagnostic
-- and POST the rows to the REST API under a temporary anon insert policy (the
-- tables are otherwise read-only to anon), then drop the temp policy.
-- ============================================================================
