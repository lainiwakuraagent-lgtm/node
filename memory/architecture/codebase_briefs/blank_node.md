# Codebase Brief: blank_node
Generated: 2026-07-26

## Directory map
tools/ (53 files)   scripts/ (20 files)   prompts/ (4 files)   config/ (2 files)

## Entry points
- scripts/wake.sh — main launcher
- scripts/conversation.sh — conversational layer
- tools/session_trigger_server.py — manual trigger server
- tools/telegram_webhook_handler.py — Telegram webhook handler

## tools/

### analytics_search.py
  def re_exec_in_venv()
  def get_embedding()
  def embedding_to_blob()
  def load_vec_extension()
  def search()
  def main()

### analytics_write.py
  def get_db()
  def init_schema()
  def read_state()
  def derive_session_key()  — Derive session key from trigger_mode + counter files.
  def find_transcript()  — Return the path to the current session's JSONL transcript.
  def parse_transcript()  — Extract token counts and tool call counts from a Claude JSON

### argus_context_poller.py
  def read_argus_url()
  def fetch_argus_status()
  def main()

### behavioral_adapter.py
  def parse_profile()  — Parse Trust/Warmth/Friction floats from a Musubi-format .md 
  def disclosure_level()  — Map Trust to (level_name, guidance_line).
  def warmth_expression()  — Map Warmth to (level_name, guidance_line).
  def friction_guard()  — Map Friction to (level_name, guidance_line).
  def load_argus_section()  — Read state/argus_context.json and return a formatted context
  def generate_context()  — Produce the behavioral context text block.

### codebase_indexer.py
  def extract_python_info()  — Extract top-level function/class names and first docstring l
  def extract_bash_info()  — Extract first description comment and function names from a 
  def scan_directory()  — Return list of (filename, items) for a directory.
  def list_directory()  — Return filenames only for a directory.
  def detect_entry_points()  — Heuristic: common entry point file names.
  def estimate_tokens()  — Rough token estimate: chars / 4.

### codebase_narrative.py
  def check_ollama()  — Return (available: bool, model_to_use: str|None).
  def call_ollama()  — Call Ollama generate API, return response text.
  def read_context_files()  — Read KEY_CONTEXT_FILES that exist; return as a dict path->co
  def build_prompt()  — Build the Ollama prompt for narrative generation.
  def read_brief()  — Read brief, return (pre_narrative: str, has_existing_narrati
  def write_brief_with_narrative()  — Overwrite the brief with the structural section + new narrat
...
(brief truncated — run codebase_indexer.py for full output)