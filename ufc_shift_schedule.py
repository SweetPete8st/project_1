import requests
from bs4 import BeautifulSoup
from datetime import datetime, timedelta, date


def get_ufc_events():
    """Scrape UFC events from the official events page."""
    url = "https://www.ufc.com/events"
    resp = requests.get(url)
    resp.raise_for_status()
    soup = BeautifulSoup(resp.text, "html.parser")
    events = []
    for card in soup.select("div.c-card-event--result"):
        name_el = card.select_one("h3.c-card-event--result__headline")
        date_el = card.select_one("div.c-card-event--result__date")
        if not name_el or not date_el:
            continue
        name = name_el.get_text(strip=True)
        date_text = date_el.get_text(strip=True)
        try:
            event_date = datetime.strptime(date_text, "%B %d, %Y").date()
        except ValueError:
            continue
        events.append({"name": name, "date": event_date})
    return events


def generate_work_dates(start: date, end: date):
    """Generate work dates for 24-on/48-off schedule, skipping Wednesdays."""
    work_dates = []
    current = start
    while current <= end:
        if current.weekday() != 2:  # 0=Mon, 1=Tue, 2=Wed
            work_dates.append(current)
        current += timedelta(days=3)
    return work_dates


def compare_schedule(events, work_dates):
    work_set = set(work_dates)
    on_shift = []
    off_shift = []
    for ev in events:
        if ev["date"] in work_set:
            on_shift.append(ev)
        else:
            off_shift.append(ev)
    return on_shift, off_shift


def main():
    start_date = date(2025, 7, 3)
    end_date = start_date + timedelta(days=365)
    events = get_ufc_events()
    work_dates = generate_work_dates(start_date, end_date)
    on_shift, off_shift = compare_schedule(events, work_dates)

    print("UFC events on work days:")
    for ev in on_shift:
        print(f"{ev['date']}: {ev['name']}")

    print("\nUFC events on days off:")
    for ev in off_shift:
        print(f"{ev['date']}: {ev['name']}")


if __name__ == "__main__":
    main()
