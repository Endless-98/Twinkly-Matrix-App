"""
High-frequency event polling system for Pygame to prevent input drops.

This module runs event polling in a dedicated thread at maximum speed,
ensuring the pygame event queue never overflows and all inputs are captured.
Events are stored in a thread-safe queue for the main game loop to consume.
"""

import pygame
import threading
import queue
import time
from logger import log


class EventPoller:
    """
    Thread-based event poller that continuously drains pygame's event queue.
    
    Prevents event drops by polling at maximum frequency and storing events
    in an unlimited thread-safe queue for later processing.
    """
    
    def __init__(self):
        self.event_queue = queue.Queue()  # Thread-safe, unlimited queue
        self.running = False
        self.thread = None
        self._stop_event = threading.Event()
        self.events_polled = 0
        self.last_log_time = time.time()
        
    def start(self):
        """Start the event polling thread."""
        if self.running:
            log("Event poller already running", level='WARNING', module="EventPoller")
            return
            
        self.running = True
        self._stop_event.clear()
        self.thread = threading.Thread(target=self._poll_loop, daemon=True)
        self.thread.start()
        log("✅ Event poller thread started", module="EventPoller")
        
    def stop(self):
        """Stop the event polling thread."""
        if not self.running:
            return
            
        self.running = False
        self._stop_event.set()
        if self.thread:
            self.thread.join(timeout=1.0)
        log(f"🛑 Event poller stopped | Total events polled: {self.events_polled}", module="EventPoller")
        
    def _poll_loop(self):
        """
        Main polling loop - runs at maximum speed to prevent queue overflow.
        
        This runs in a separate thread and continuously drains pygame's event queue,
        storing all events in our unlimited thread-safe queue.
        """
        while self.running and not self._stop_event.is_set():
            try:
                # Get ALL pending events in one batch
                events = pygame.event.get()
                
                if events:
                    for event in events:
                        self.event_queue.put(event)
                        self.events_polled += 1
                    
                    # Periodic logging of polling stats
                    current_time = time.time()
                    if current_time - self.last_log_time >= 10.0:
                        queue_size = self.event_queue.qsize()
                        log(f"📊 Event poller stats | Polled: {self.events_polled} | Queue size: {queue_size}", 
                            module="EventPoller")
                        self.last_log_time = current_time
                
                # Yield CPU briefly to prevent 100% usage, but keep polling very fast
                time.sleep(0.0001)  # 0.1ms - poll at ~10,000 Hz
                
            except Exception as e:
                log(f"Error in event polling loop: {e}", level='ERROR', module="EventPoller")
                time.sleep(0.001)  # Back off on error
                
    def get_events(self):
        """
        Get all pending events from the queue.
        
        Returns:
            list: All events currently in the queue (may be empty)
        """
        events = []
        while not self.event_queue.empty():
            try:
                events.append(self.event_queue.get_nowait())
            except queue.Empty:
                break
        return events
    
    def has_events(self):
        """Check if there are any pending events."""
        return not self.event_queue.empty()
    
    def queue_size(self):
        """Get the current number of pending events."""
        return self.event_queue.qsize()
