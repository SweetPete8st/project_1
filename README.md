# project_1

This repository contains a simple script to compare upcoming UFC fight cards with a rotating shift schedule.

## Usage

1. Install Python dependencies:
   ```bash
   pip install -r requirements.txt
   ```
   (Requires internet access.)

2. Run the script:
   ```bash
   python3 ufc_shift_schedule.py
   ```

The script assumes the next shift begins on **Thursday, July 3, 2025**. It uses a 24‑hour on/48‑hour off rotation while skipping all Wednesdays. The script scrapes `https://www.ufc.com/events` for upcoming fight dates and reports which cards fall on work days and which fall on days off.
