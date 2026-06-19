# import FastAPI (optional if you still want API)
from fastapi import FastAPI

# import watchdog components
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

# import system modules
import time
import threading

# import tkinter for folder selection dialog
import tkinter as tk
from tkinter import filedialog


# create FastAPI app (you can keep or remove if not needed)
app = FastAPI()


# ✅ handler for file events
class FolderHandler(FileSystemEventHandler):

    # triggered when a new file is created
    def on_created(self, event):

        # ignore folders
        if not event.is_directory:

            # print detected file
            print(f"✅ New file detected: {event.src_path}")


    # triggered when file is modified
    def on_modified(self, event):

        # ignore folders
        if not event.is_directory:

            # print modification
            print(f"✏️ File modified: {event.src_path}")


# ✅ function to ask user for folder
def choose_folder():

    # create hidden tkinter window
    root = tk.Tk()
    root.withdraw()

    # open folder selection dialog
    folder_selected = filedialog.askdirectory(title="Select folder to monitor")

    return folder_selected


# ✅ watcher function
def start_watching(folder_path):

    # create observer
    observer = Observer()

    # assign handler
    observer.schedule(FolderHandler(), folder_path, recursive=False)

    # start observer
    observer.start()

    print("\n👀 Watching folder:")
    print(f"👉 {folder_path}\n")

    try:
        # keep app alive
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()

    observer.join()


# ✅ startup logic
def main():

    print("🚀 Starting application...")

    # ask user to pick folder
    folder = choose_folder()

    # check if user canceled
    if not folder:
        print("❌ No folder selected. Exiting...")
        return

    # start watcher
    start_watching(folder)


# ✅ run app
if __name__ == "__main__":
    main()