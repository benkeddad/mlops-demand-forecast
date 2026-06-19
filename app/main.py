from fastapi import FastAPI
import os
import threading
import time

from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler


app = FastAPI()


# ✅ paths
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(BASE_DIR)

DATA_FOLDER = os.path.join(PROJECT_ROOT, "data", "raw")
COUNTER_FILE = os.path.join(BASE_DIR, "counter.txt")


# ✅ initialize counter
def initialize_counter():
    if not os.path.exists(COUNTER_FILE):
        with open(COUNTER_FILE, "w") as f:
            f.write("0")


# ✅ increment counter
def increment_counter():
    with open(COUNTER_FILE, "r") as f:
        value = int(f.read())

    value += 1

    with open(COUNTER_FILE, "w") as f:
        f.write(str(value))

    print(f"✅ Counter updated: {value}")


# ✅ watchdog handler
class DataHandler(FileSystemEventHandler):

    def on_created(self, event):
        if not event.is_directory:
            print(f"📁 New file detected: {event.src_path}")
            increment_counter()


# ✅ watcher loop
def start_watching():

    initialize_counter()

    os.makedirs(DATA_FOLDER, exist_ok=True)

    observer = Observer()
    observer.schedule(DataHandler(), DATA_FOLDER, recursive=False)

    observer.start()

    print("👀 Watching for new files in data/raw...")

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()

    observer.join()


# ✅ run watcher when FastAPI starts
@app.on_event("startup")
def startup():

    thread = threading.Thread(target=start_watching, daemon=True)
    thread.start()


# ✅ endpoint to check counter
@app.get("/counter")
def get_counter():
    with open(COUNTER_FILE, "r") as f:
        return {"counter": f.read()}