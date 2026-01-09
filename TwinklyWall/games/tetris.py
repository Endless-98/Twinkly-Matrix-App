# All code in this file must be handwritten! No AI allowed!

# TODO
    # 7 Bag Draw
    # Rotation
    # Soft and Hard drop
    # Proper locking at the right times
    # Add higher buffer ceiling
    # T-spin
    # Scoring
        # Scoring system, including Back-to-Back recognition rules
        # Combo recognition
        # Perfect clear recognition (for later games)

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

class Tetromino:
    size = 4

    def __init__(self, type_index, position = (0,0), rotation = 0):
        self.position = position
        self.shapes = [ [], # Empty piece
            # I piece
            [[0,0,0,0],
             [0,0,0,0],
             [1,1,1,1],
             [0,0,0,0]],
            # J piece
            [[0,0,0,0],
             [2,0,0,0],
             [2,2,2,0],
             [0,0,0,0]],
            # L piece
            [[0,0,0,0],
             [0,0,0,3],
             [0,3,3,3],
             [0,0,0,0]],
            # O piece
            [[0,0,0,0],
             [0,4,4,0],
             [0,4,4,0],
             [0,0,0,0]],
            # S piece
            [[0,0,0,0],
             [0,0,5,5],
             [0,5,5,0],
             [0,0,0,0]],
            # Z piece
            [[0,0,0,0],
             [6,6,0,0],
             [0,6,6,0],
             [0,0,0,0]],
            # T piece
            [[0,0,0,0],
             [0,7,0,0],
             [7,7,7,0],
             [0,0,0,0]], ]
        self.shape = self.shapes[type_index]

class Tetris:
    def __init__(self, canvas, HEADLESS):
        self.headless = HEADLESS
        self.blocks_width = 10
        self.blocks_height = 15 # Only 16.5 visible on matrix with current setup
        self.block_size = 3
        self.border_thickness = 2
        self.border_color = (105,105,105)
        self.screen = canvas
        self.players = get_active_players_for_game
        self.live_drop_tetromino = None
        self.is_playing = True
        self.drop_interval_secs = 0.350
        self.drop_time_elapsed = 0
        self.colors = [(0,0,0), (0, 230, 254), (24, 1, 255), (255, 115, 8), (255, 222, 0), (102, 253, 0), (254, 16, 60), (184, 2, 253)]

        self.game_x_offset = self.screen.get_width() / self.block_size - self.blocks_width -1
        self.game_y_offset = self.screen.get_height() / self.block_size - self.blocks_height - 1
        # Random grid for debug
        # self.dead_grid = [[random.randrange(0, len(self.colors)) for element in range(self.blocks_height)] for row in range(self.blocks_width)]
        self.dead_grid  = [[0 for element in range(self.blocks_height)] for row in range(self.blocks_width)]
        self.spawn_tetromino()

    def draw_square(self, color_index, position):
        pygame.draw.rect(self.screen, self.colors[color_index], (position[0], position[1], self.block_size, self.block_size))
    
    def draw_border(self):
        x_left = int(self.game_x_offset * self.block_size) - self.border_thickness
        x_right = int(self.game_x_offset * self.block_size + (self.blocks_width * self.block_size))
        pygame.draw.rect(self.screen, self.border_color, (x_left, 0, self.border_thickness, 1000,))
        pygame.draw.rect(self.screen, self.border_color, (x_right, 0, self.border_thickness, 1000,))

    def spawn_tetromino(self):
        piece_width = Tetromino.size
        self.live_tetromino = Tetromino(random.randrange(1, len(self.colors)), position=((self.blocks_width - piece_width) // 2,12)) # Switch to 7 bag method later
        # self.live_tetromino = Tetromino(3, position=((self.blocks_width - piece_width) // 2,12)) # Switch to 7 bag method later
   
    def move_tetromino(self, offset:()):
        new_position = (self.live_tetromino.position[0] + offset[0], self.live_tetromino.position[1] + offset[1])
        if not self.check_move_validity(new_position):
            self.lock_piece() # Temporary
            return False
        self.live_tetromino.position = new_position

    def check_move_validity(self, test_postion : ()) -> bool:
        grid = self.dead_grid
        pos = test_postion

        for local_x, grid_x in enumerate(range(pos[0], pos[0] + 4)): # TODO: Duplicate code from tick function. Find encapsulation method
            for local_y, grid_y in enumerate(range(pos[1], pos[1] + 4)):
                tetromino_cell_value = self.live_tetromino.shape[-local_y + 3][local_x] 
                if tetromino_cell_value != 0: 
                    if grid_x < 0 or grid_y < 0: 
                        return False
                    if grid[grid_x][grid_y] != 0:
                        return False

        return True

    def rotate_tetromino(self):
        size = Tetromino.size
        rotated_shape = [[0 for _ in range(size)] for _ in range(size)]
        for x, row in enumerate(self.live_tetromino.shape):
            for y, cell in enumerate(row):
                rotated_shape[y][x] = cell
        for row in rotated_shape:
            row = row.reverse()
        self.live_tetromino.shape = rotated_shape

    def lock_piece(self):
        pos = self.live_tetromino.position
        for local_x, grid_x in enumerate(range(pos[0], pos[0] + 4)):# TODO: Duplicate code. Find encapsulation
            for local_y, grid_y in enumerate(range(pos[1], pos[1] + 4)):
                tetromino_cell_value = self.live_tetromino.shape[-local_y + 3][local_x] # Invert y because the origin is in the bottom left of the grid
                if tetromino_cell_value != 0:
                    self.dead_grid[grid_x][grid_y] = tetromino_cell_value

        self.spawn_tetromino()

    def tick(self, delta_time): # Called in main

        self.drop_time_elapsed += delta_time
        if self.drop_time_elapsed >= self.drop_interval_secs:
            self.move_tetromino(offset=(0,-1))
            self.drop_time_elapsed = 0

        if not self.headless:
            self.screen.fill((35,35,35)) # Help the preview pixels to stand out from the black background
            pygame.display.flip()

        # Draw dead cells
        grid = copy.deepcopy(self.dead_grid) # Perform deep copy
        # Draw tetromino on top of dead_grid
        pos = self.live_tetromino.position
        for local_x, grid_x in enumerate(range(pos[0], pos[0] + 4)):
            for local_y, grid_y in enumerate(range(pos[1], pos[1] + 4)):
                tetromino_cell_value = self.live_tetromino.shape[-local_y + 3][local_x] # Invert y because the origin is in the bottom left of the grid
                if tetromino_cell_value != 0:
                    grid[grid_x][grid_y] = tetromino_cell_value
                
        for x_index, row in enumerate(grid):
            x_position = x_index + self.game_x_offset 
            for y_index, value in enumerate(row): 
                y_position = self.blocks_height - y_index + self.game_y_offset
                color_index = grid[x_index][y_index]
                pos = (x_position * self.block_size, y_position * self.block_size)
                self.draw_square(color_index, pos)
        
        self.draw_border()

                
    def begin_play(self): # Called in main
        self.bind_input(self)   

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
                        case "ROTATE_RIGHT":
                            tetris.rotate_clockwise()
                        case "ROTATE_LEFT":
                            tetris.rotate_counterclockwise()
                        case "MOVE_DOWN":
                            tetris.hard_drop_piece()
                return handle_tetris_input
            set_input_handler(player.player_id, make_input_handler())
       
    def move_piece_left(self):
        log("LEFT", module="Tetris")
        self.move_tetromino(offset=(-1,0))

    def move_piece_right(self):
        log("RIGHT", module="Tetris")
        self.move_tetromino(offset=(1,0))

    def rotate_clockwise(self):
        log("ROTATE_CLOCKWISE", module="Tetris")
        self.rotate_tetromino()

    def rotate_counterclockwise(self):
        log("ROTATE__COUNTER_CLOCKWISE", module="Tetris")
        self.rotate_tetromino()

    def hard_drop_piece(self):
        log("HARD_DROP_PIECE", module="Tetris")