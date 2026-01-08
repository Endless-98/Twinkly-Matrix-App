# All code in this file must be handwritten! No AI allowed!

import sys
import os
import pygame
import numpy
import random
from logger import log
from game_players import get_active_players_for_game, get_game_for_player
from players import set_input_handler
from pathlib import Path

class Tetris:
    def __init__(self, canvas, HEADLESS):
        pygame.init() # Redundant?
        
        self.headless = HEADLESS
        self.blocks_width = 10
        self.blocks_height = 15 # Only 16.5 visible with current setup
        self.block_size = 3
        self.screen = canvas
        self.players = get_active_players_for_game

        # There is probably a more concise way to do this:
        project_dir = Path(__file__).resolve().parent
        assets_file_path = (str)(project_dir / "assets")
        self.block_images = [pygame.image.load(assets_file_path + "/TetrisSquare_Empty.png"),
            pygame.image.load(assets_file_path + "/TetrisSquare_Blue.png"),
            pygame.image.load(assets_file_path + "/TetrisSquare_Green.png"),
            pygame.image.load(assets_file_path + "/TetrisSquare_Orange.png"),
            pygame.image.load(assets_file_path + "/TetrisSquare_Purple.png"),
            pygame.image.load(assets_file_path + "/TetrisSquare_Red.png"),
            pygame.image.load(assets_file_path + "/TetrisSquare_Yellow.png")
            ]
        for index in range(len(self.block_images)):
            self.block_images[index] = pygame.transform.scale(self.block_images[index], (self.block_size, self.block_size))

        self.grid = [[]]
        empty_block = "assets/tetris_blocks/TetrisSquare_Empty.png"
        self.grid = [[random.randrange(0, len(self.block_images)) for element in range(self.blocks_width)] for row in range(self.blocks_height)]
        print(self.screen.get_height())
   
    def bind_input(self):
        players = get_active_players_for_game("tetris")
        for i, player in enumerate(players):
            def make_input_handler(player_index=i):
                def handle_tetris_input(self):
                    cmd = payload.get("cmd")
                    match cmd:
                        case "MOVE_LEFT":
                            move_piece_left()
                        case "MOVE_RIGHT":
                            move_piece_right()
                        case "ROTATE_CLOCKWISE":
                            rotate_clockwise()
                        case "ROTATE_COUNTERCLOCKWISE":
                            rotate_counterclockwise()
                        case "HARD_DROP":
                            hard_drop_piece()
                return on_input
            set_input_handler(player.player_id, make_input_handler())
        
       
    def move_piece_left():
        log("LEFT")
    def move_piece_right():
        log("RIGHT")

    def rotate_clockwise():
        log("ROTATE_CLOCKWISE")

    def rotate_counterclockwise():
        log("ROTATE__COUNTER_CLOCKWISE")

    def hard_drop_piece():
        log("HARD_DROP_PIECE")

    def tick(self): # Called in main
        
        if not self.headless:
            self.screen.fill((35,35,35)) # Help the preview pixels to stand out from the black background
            pygame.display.flip()

        x_offset = self.screen.get_width() // self.block_size
        y_offset = self.blocks_height - (self.screen.get_height() / (self.block_size))
        # Draw cells
        for y_index, row in enumerate(self.grid):
            y_position = y_index - y_offset 
            for x_index, value in enumerate(row):
                x_position = x_offset - x_index - 1
                self.screen.blit(self.block_images[self.grid[y_index][x_index]], (x_position * self.block_size, (y_position * self.block_size)) )