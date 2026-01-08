# All code in this file must be handwritten! No AI allowed!

import sys
import os
import pygame
import numpy
import random
from game_players import get_active_players_for_game, get_game_for_player
from players import set_input_handler

class Tetris:
    def __init__(self, canvas, HEADLESS):
        pygame.init() # Redundant?
        
        self.headless = HEADLESS
        self.blocks_width = 10
        self.blocks_height = 16
        self.block_size = 3
        print(f"block_size: {self.block_size}")
        self.screen = canvas
        self.players = get_active_players_for_game

        self.block_images = [pygame.image.load("assets/tetris_blocks/TetrisSquare_Empty.png"),
            pygame.image.load("assets/tetris_blocks/TetrisSquare_Blue.png"),
            pygame.image.load("assets/tetris_blocks/TetrisSquare_Green.png"),
            pygame.image.load("assets/tetris_blocks/TetrisSquare_Orange.png"),
            pygame.image.load("assets/tetris_blocks/TetrisSquare_Purple.png"),
            pygame.image.load("assets/tetris_blocks/TetrisSquare_Red.png"),
            pygame.image.load("assets/tetris_blocks/TetrisSquare_Yellow.png")
            ]
        for index in range(len(self.block_images)):
            self.block_images[index] = pygame.transform.scale(self.block_images[index], (self.block_size,self.block_size))

        self.grid = [[]]
        empty_block = "assets/tetris_blocks/TetrisSquare_Empty.png"
        self.grid = [[random.randrange(0, len(self.block_images)) for element in range(self.blocks_width)] for row in range(self.blocks_height)]

    # def bind_input():
    #     for index, player in enumerate(players):
    #         def on_input()

    def tick(self): # Called in main
        self.screen.fill((35,35,35)) # Help the preview pixels to stand out from the black background
        
        if not self.headless:
            pygame.display.flip()

        x_offset = self.screen.get_width() // self.block_size
        y_offset = numpy.round(self.blocks_height - (self.screen.get_height() / self.block_size), decimals=0).astype(int)
        # Draw cells
        for y_index, row in enumerate(self.grid):
            y_position = y_index - y_offset
            for x_index, value in enumerate(row):
                x_position = x_offset - x_index - 1
                self.screen.blit(self.block_images[self.grid[y_index][x_index]], (x_position * self.block_size, (y_position * self.block_size) -1) )