import requests
import json


class FPPController:
    def __init__(self, fpp_host="localhost", fpp_port=32322):
        self.fpp_host = fpp_host
        self.fpp_port = fpp_port
        self.base_url = f"http://{fpp_host}:{fpp_port}/api"
        self.timeout = 5
    
    def get_status(self):
        """Get FPP daemon status"""
        try:
            response = requests.get(f"{self.base_url}/system/status", timeout=self.timeout)
            return response.json()
        except Exception as e:
            return None
    
    def enable_pixel_overlay(self, model_name="Light_Wall"):
        """Enable Pixel Overlay Model State for specified model"""
        try:
            # URL encode the command properly
            command = f"Pixel Overlay Model State"
            command_url = f"{self.base_url}/command/{command.replace(' ', '%20')}/{model_name}/1"
            
            response = requests.get(command_url, timeout=self.timeout)
            
            if response.status_code == 200:
                print(f"✓ Pixel Overlay enabled for {model_name}")
                return True
            else:
                print(f"✗ Failed to enable Pixel Overlay: {response.status_code}")
                print(f"  Response: {response.text}")
                return False
                
        except requests.exceptions.ConnectionError:
            return False
        except Exception as e:
            return False
    
    def is_connected(self):
        """Check if FPP API is accessible"""
        try:
            response = requests.get(f"{self.base_url}/system/status", timeout=self.timeout)
            return response.status_code == 200
        except:
            return False


def setup_fpp_overlay(model_name="Light_Wall"):
    """Initialize FPP and enable pixel overlay (non-fatal if API unavailable)"""
    controller = FPPController()
    
    if not controller.is_connected():
        print("Note: FPP API not accessible (but direct file writing should work)")
        return
    
    status = controller.get_status()
    if status:
        print(f"FPP Status: {status.get('status_name', 'Unknown')}")
    
    return controller.enable_pixel_overlay(model_name)
