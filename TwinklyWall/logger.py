"""
Simple debug logging module for TwinklyWall.

Provides a single log() function that works with FPP debug mode and regular output.
"""

import os
import sys
import time
from datetime import datetime


class DebugLogger:
    """Lightweight logging system optimized for FPP debug mode."""
    
    def __init__(self):
        self.debug_mode = os.environ.get('TWINKLYWALL_DEBUG', '').lower() in ('1', 'true', 'yes')
        self.fpp_debug = os.environ.get('FPP_DEBUG', '').lower() in ('1', 'true', 'yes')
        self.log_file = os.environ.get('TWINKLYWALL_LOG_FILE', None)
        self.start_time = time.time()
        
    def log(self, message, level='INFO', module=None):
        """
        Log a message.
        
        Args:
            message: The message to log
            level: Log level (DEBUG, INFO, WARNING, ERROR)
            module: Optional module name for context
        """
        if not self.debug_mode and not self.fpp_debug:
            return
        
        timestamp = datetime.now().strftime("%H:%M:%S.%f")[:-3]
        elapsed = f"{(time.time() - self.start_time):.2f}s"
        
        if module:
            prefix = f"[{timestamp}] [{module}] [{level}]"
        else:
            prefix = f"[{timestamp}] [{level}]"
        
        output = f"{prefix} {message}"
        
        # Always print to stdout
        print(output)
        
        # Also write to file if configured
        if self.log_file:
            try:
                with open(self.log_file, 'a') as f:
                    f.write(output + '\n')
            except Exception as e:
                print(f"Warning: Could not write to log file: {e}")
    
    def debug(self, message, module=None):
        """Log a debug message."""
        self.log(message, 'DEBUG', module)
    
    def info(self, message, module=None):
        """Log an info message."""
        self.log(message, 'INFO', module)
    
    def warning(self, message, module=None):
        """Log a warning message."""
        self.log(message, 'WARN', module)
    
    def error(self, message, module=None):
        """Log an error message."""
        self.log(message, 'ERROR', module)


# Global logger instance
_logger = DebugLogger()


# Public API - single function as requested
def log(message, level='INFO', module=None):
    """
    Log a message to debug output.
    
    Usage:
        from logger import log
        log("Something happened")
        log("Game started", module="Tetris")
        log("Error occurred", level='ERROR', module="VideoPlayer")
    
    Enable logging with environment variables:
        export TWINKLYWALL_DEBUG=1       # Enable debug mode
        export TWINKLYWALL_LOG_FILE=/tmp/twinklywall.log  # Optional: write to file
    
    Args:
        message: The message to log
        level: Log level - 'DEBUG', 'INFO', 'WARNING', 'ERROR' (default: 'INFO')
        module: Optional module name for context
    """
    _logger.log(message, level, module)


# Convenience functions
def debug(message, module=None):
    """Log a debug message."""
    _logger.debug(message, module)


def info(message, module=None):
    """Log an info message."""
    _logger.info(message, module)


def warning(message, module=None):
    """Log a warning message."""
    _logger.warning(message, module)


def error(message, module=None):
    """Log an error message."""
    _logger.error(message, module)
