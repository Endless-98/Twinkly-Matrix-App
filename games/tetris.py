# All code in this file must be handwritten!

import sys
import os
import pygame

def init_game(matrix, window_width, window_height):
    pygame.init() # Redundant?
    
    blocks_width = 10
    blocks_height = 20
    grid = numpy.full((blocks_height, blocks_width), False, dtype=bool)
    
    screen = pygame.display.set_mode((window_width, window_height))

    game_running = True
    try:
        while game_running:
            screen.fill((255,255,255))
            pygame.display.flip()

    except KeyboardInterrupt:
        pass
    finally: 
        matrix.shutdown 
        pygame.quit()
        sys.exit()

def tick(): # Called in main

    def draw_cells(grid):
        for x in range(blocks_width):
            for y in range(blocks_height):
                pass
