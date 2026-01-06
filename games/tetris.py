# All code in this file must be handwritten!

import sys
import os
import pygame
import numpy


class Tetris:
    def __init__(self, canvas, HEADLESS):
        pygame.init() # Redundant?
        
        self.headless = HEADLESS
        self.blocks_width = 10
        self.blocks_height = 20
        self.block_size = canvas.get_height() / self.blocks_height
        print(f"block_size: {self.block_size}")
        self.grid = numpy.full((self.blocks_height, self.blocks_width), False, dtype=bool)
        self.screen = canvas

        self.block_image = pygame.image.load("assets/TetrisSquare_Red.png")
        self.block_image = pygame.transform.scale(self.block_image, (self.block_size,self.block_size))

        print(self.screen.get_width())

    def tick(self): # Called in main
        self.screen.fill((35,35,35))
        
        if not self.headless:
            pygame.display.flip()

        x_start = numpy.round(self.screen.get_width() / self.block_size).astype(int)
        # Draw cells
        for x in range(x_start, x_start - 1 - self.blocks_width, -1):
            for y in range(self.blocks_height):
                self.screen.blit(self.block_image, (x * self.block_size, y * self.block_size) )
