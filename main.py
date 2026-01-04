import time
import dotmatrix.dot_matrix as DotMatrix

friendly_current_time = time.time()
sleep_duration_secs = 1

def master_loop():
    while True:
        friendly_current_time = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
        print(f"Current Time: {friendly_current_time}")
        time.sleep(sleep_duration_secs)

def main():
    # master_loop()
    matrix = DotMatrix.DotMatrix(show_source_preview=True)
    matrix.render_sample_pattern()
    # time.sleep(1)
    # matrix.render_image("assets/sample_image.jpg")

    matrix.wait_for_exit()

if __name__ == "__main__":
    main()