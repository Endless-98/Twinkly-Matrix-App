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
import copy
import time


class Tetrominoe:
    def __init__(self, type_index, position = (0,0), rotation = 0):
        self.position = position
        self.shape = None
        match type_index:
            case 0: # I piece
                self.shape = [[0,0,0,0],
                              [1,1,1,1],
                              [0,0,0,0],
                              [0,0,0,0]]
                              
            case 1: # J piece
                self.shape = [[0,0,0,0],
                              [2,0,0,0],
                              [2,2,2,0],
                              [0,0,0,0]]
            case 2: # L piece
                self.shape = [[0,0,0,0],
                              [0,0,0,3],
                              [0,3,3,3],
                              [0,0,0,0]]
            case 3: # O piece
                self.shape = [[0,0,0,0],
                              [0,4,4,0],
                              [0,4,4,0],
                              [0,0,0,0]]
            case 4: # S piece
                self.shape = [[0,0,0,0],
                              [0,0,5,5],
                              [0,5,5,0],
                              [0,0,0,0]]
            case 5: # Z piece
                self.shape = [[0,0,0,0],
                              [6,6,0,0],
                              [0,6,6,0],
                              [0,0,0,0]]
            case 6: # T piece
                self.shape = [[0,0,0,0],
                              [0,7,0,0],
                              [7,7,7,0],
                              [0,0,0,0]]



class Tetris:
    def __init__(self, canvas, HEADLESS):
        self.headless = HEADLESS
        self.blocks_width = 10
        self.blocks_height = 15 # Only 16.5 visible on matrix with current setup
        self.block_size = 3
        self.screen = canvas
        self.players = get_active_players_for_game
        self.live_tetrominoe = Tetrominoe(random.randrange(0,6), position=(0,12))
        self.is_playing = True
        self.drop_interval_secs = 0.150
        self.drop_time_elapsed = 0
        self.colors = [(0,0,0), (0, 230, 254), (24, 1, 255), (255, 115, 8), (255, 222, 0), (102, 253, 0), (254, 16, 60), (184, 2, 253)]

        # Random grid for debug
        # self.dead_grid = [[random.randrange(0, len(self.colors)) for element in range(self.blocks_height)] for row in range(self.blocks_width)]
        self.dead_grid  = [[0 for element in range(self.blocks_height)] for row in range(self.blocks_width)]

    def draw_square(self, color_index, position):
        pygame.draw.rect(self.screen, self.colors[color_index], (position[0], position[1], self.block_size, self.block_size))

    def spawn_tetrominoe(self):
        return Tetrominoe(random.randrange(0,6)) # Switch to 7 bag method later
   
    def drop_tetrominoe(self):
        if self.live_tetrominoe.position[1] < 0: # TODO: Better logic for reaching floor or coming up against another piece
            self.live_tetrominoe.position = (self.live_tetrominoe.position[0],) + (12,)
            return
        self.live_tetrominoe.position = (self.live_tetrominoe.position[0],) + (self.live_tetrominoe.position[1] - 1,)

    def move_tetrominoe_left(self):
        self.live_tetrominoe.position = (self.live_tetrominoe.position[0] - 1,) + (self.live_tetrominoe.position[1],)

    def move_tetrominoe_right(self):
        self.live_tetrominoe.position = (self.live_tetrominoe.position[0] + 1,) + (self.live_tetrominoe.position[1],)

    def bind_input(self, tetris):
        players = get_active_players_for_game("tetris")
        for i, player in enumerate(players):
            def make_input_handler(player_index=i):
                def handle_tetris_input(player_obj, payload):
                    cmd = payload.get("cmd")
                    match cmd:
                        case "MOVE_LEFT":
                            tetris.move_piece_left()
                        case "MOVE_RIGHT":
                            tetris.move_piece_right()
                        case "ROTATE_CLOCKWISE":
                            tetris.rotate_clockwise()
                        case "ROTATE_COUNTERCLOCKWISE":
                            tetris.rotate_counterclockwise()
                        case "MOVE_DOWN":
                            tetris.hard_drop_piece()
                return handle_tetris_input
            set_input_handler(player.player_id, make_input_handler())
       
    def move_piece_left(self):
        log("LEFT", module="Tetris")
        self.move_tetrominoe_left()

    def move_piece_right(self):
        log("RIGHT", module="Tetris")
        self.move_tetrominoe_right()

    def rotate_clockwise(self):
        log("ROTATE_CLOCKWISE", module="Tetris")

    def rotate_counterclockwise(self):
        log("ROTATE__COUNTER_CLOCKWISE", module="Tetris")

    def hard_drop_piece(self):
        log("HARD_DROP_PIECE", module="Tetris")

    def begin_play(self): # Called in main
        self.bind_input(self)     

    def tick(self, delta_time): # Called in main
        self.drop_time_elapsed += delta_time
        if self.drop_time_elapsed >= self.drop_interval_secs:
            self.drop_tetrominoe()
            self.drop_time_elapsed = 0

        if not self.headless:
            self.screen.fill((35,35,35)) # Help the preview pixels to stand out from the black background
            pygame.display.flip()

        x_offset = self.screen.get_width() / self.block_size - self.blocks_width
        y_offset = self.screen.get_height() / self.block_size - self.blocks_height - 1
        # Draw dead cells
        grid = copy.deepcopy(self.dead_grid) # Perform deep copy
        # Draw tetrominoe on top of dead_grid
        pos = self.live_tetrominoe.position
        for local_x, grid_x in enumerate(range(pos[0], pos[0] + 4)):
            for local_y, grid_y in enumerate(range(pos[1], pos[1] + 4)):
                tetrominoe_cell_value = self.live_tetrominoe.shape[-local_y + 3][local_x] # Invert y because the origin is in the bottom left of the grid
                if tetrominoe_cell_value != 0:
                    grid[grid_x][grid_y] = tetrominoe_cell_value
                
        for x_index, row in enumerate(grid):
            x_position = x_index + x_offset 
            for y_index, value in enumerate(row): 
                y_position = self.blocks_height - y_index + y_offset
                # print(f"y_position: {y_position}")
                # print(f"y_index: {y_index}")
                # self.screen.blit(self.block_images[grid[x_index][y_index]], (x_position * self.block_size, y_position * self.block_size))
                color_index = grid[x_index][y_index]
                pos = (x_position * self.block_size, y_position * self.block_size)
                self.draw_square(color_index, pos)
