# All code in this file must be handwritten! No AI allowed!

# TODO
    # Hard drop
    # Ghost piece
    # Tidy piece preview
    # Super Rotation System 
        # (also known as SRS) specifies tetromino rotation and wall kicks. SRS defines 5 points of rotation, each with a different purpose.
        # Visual rotation - The natural rotation of a tetromino. 
        # Right/Left wall kick - Kick off an obstruction on the right or left.
        # Floor kick - Kick off the floor, for when a tetromino has landed. Without kicks no rotation would be possible in some cases.
        # Out of right well kick - If a tetromino is in a well, it can be rotated out.
        # Out of left well kick - If a tetromino is in a well, it can be rotated out.
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
    shapes = [ [], # Empty piece (0)
                # I piece (1)
                [[0,0,0,0],
                [0,0,0,0],
                [1,1,1,1],
                [0,0,0,0]],
                # J piece (2)
                [[0,0,0,0],
                [2,0,0,0],
                [2,2,2,0],
                [0,0,0,0]],
                # L piece (3)
                [[0,0,0,0],
                [0,0,0,3],
                [0,3,3,3],
                [0,0,0,0]],
                # O piece (4)
                [[0,0,0,0],
                [0,4,4,0],
                [0,4,4,0],
                [0,0,0,0]],
                # S piece (5)
                [[0,0,0,0],
                [0,0,5,5],
                [0,5,5,0],
                [0,0,0,0]],
                # Z piece (6)
                [[0,0,0,0],
                [6,6,0,0],
                [0,6,6,0],
                [0,0,0,0]],
                # T piece (7)
                [[0,0,0,0],
                [0,7,0,0],
                [7,7,7,0],
                [0,0,0,0]], ]
    def __init__(self, type_index, grid_position = (0,0), rotation = 0):
        self.grid_position = grid_position
        self.precise_height = 0.0 # Won't fall on the grid, but we snap to grid.
        self.ghost_opacity = 0.2
        self.type_index = type_index
        self.shape = self.shapes[type_index]

class Random_Bag:
    bag_size = 7
    
    def __init__(self):
        self.contents = []
        self.next_piece = None
        
    def refill_bag(self):
        new_bag = [i for i in range(1,self.bag_size + 1)]
        random.shuffle(new_bag)
        print(f"New bag: {new_bag}")
        self.contents = new_bag
        if self.next_piece == None: # Should happen only on the first bag fill 
            self.next_piece = self.contents.pop()
    
    def pull_piece(self) -> int:
        if len(self.contents) <= 0:
            self.refill_bag()

        new_piece = self.next_piece
        self.next_piece = self.contents.pop()
        
        print(f"Current bag: {self.contents}")
        print(f"Current piece: {new_piece}")
        print(f"Next piece: {self.next_piece}")
        return new_piece

class Tetris:
    def __init__(self, canvas, HEADLESS):
        ### Settings ###
        self.headless = HEADLESS
        self.blocks_width = 10
        self.blocks_height = 15 # Only 16.5 visible on matrix with current setup
        self.block_size = 3
        self.border_thickness = 2
        self.border_color = (105,105,105)
        self.screen = canvas

        self.level = 1
        self.speed_increment = 0.007
        self.base_speed = 0.8
        self.gravity = 0
        self.accumulated_gravity = 0
        self.players = get_active_players_for_game 
        self.live_tetromino = None
        self.is_playing = True
        self.max_lock_down_time = 0.500
        self.down_time_elapsed = 0.0
        self.is_down = False
        self.max_moves_while_down = 15
        self.moves_while_down = 0
        self.colors = [(0,0,0), (0, 230, 254), (24, 1, 255), (255, 115, 8), (255, 222, 0), (102, 253, 0), (254, 16, 60), (184, 2, 253)]
        self.bag = Random_Bag()

        self.game_x_offset = self.screen.get_width() / self.block_size - self.blocks_width -1
        self.game_y_offset = self.screen.get_height() / self.block_size - self.blocks_height - 1
        self.dead_grid  = [[0 for element in range(self.blocks_width)] for row in range(self.blocks_height)]
        self.calc_gravity()
        self.spawn_tetromino()

    def calc_gravity(self): # TODO: Call every level change
        self.gravity = numpy.power((self.base_speed - ((self.level - 1) * self.speed_increment)), self.level)

    def drop_tetromino_by_gravity(self, fps):
        frame_adjusted_gravity = self.gravity / fps
        original_height = self.live_tetromino.precise_height
        new_height = original_height - (frame_adjusted_gravity + self.accumulated_gravity)
        self.live_tetromino.precise_height = new_height
        height_precise_delta = original_height - new_height
        height_grid_delta = int(numpy.floor(height_precise_delta))
        if height_grid_delta > 0:
            for _ in range(height_grid_delta):
                self.is_down = not self.move_tetromino(offset=(0, -1))
            # self.rotate_tetromino() # For debug only

        if not self.is_down:
            self.reset_down()
        self.accumulated_gravity = height_precise_delta - height_grid_delta

    def draw_square(self, color_index, position):
        pygame.draw.rect(self.screen, self.colors[color_index], (position[0], position[1], self.block_size, self.block_size))
    
    def draw_border(self):
        x_left = int(self.game_x_offset * self.block_size) - self.border_thickness
        x_right = int(self.game_x_offset * self.block_size + (self.blocks_width * self.block_size))
        pygame.draw.rect(self.screen, self.border_color, (x_left, 0, self.border_thickness, 1000,))
        pygame.draw.rect(self.screen, self.border_color, (x_right, 0, self.border_thickness, 1000,))

    def draw_next_piece_preview(self):
        thickness = self.block_size + Tetromino.size + 4
        x_left = int(self.game_x_offset * self.block_size) - thickness - self.border_thickness
        pygame.draw.rect(self.screen, self.border_color, (x_left, 0, thickness, thickness,))
        
        self.draw_tetromino(grid_position=(-4,13), type_index=self.bag.next_piece)

    def spawn_tetromino(self):
        piece_width = Tetromino.size
        piece_type = self.bag.pull_piece()
        # self.live_tetromino = Tetromino(piece_type, grid_position=((self.blocks_width - piece_width) // 2, self.blocks_height - Tetromino.size))
        self.live_tetromino = Tetromino(piece_type, grid_position=(0, self.blocks_height - Tetromino.size))
   
    def move_tetromino(self, offset:()) -> bool:
        new_position = (self.live_tetromino.grid_position[0] + offset[0], self.live_tetromino.grid_position[1] + offset[1])

        if not self.check_move_validity(test_postion=new_position):
            return False
        self.live_tetromino.grid_position = new_position
        return True

    def check_move_validity(self, test_postion : () = None, test_shape = None) -> bool:
        grid = self.dead_grid
        if test_shape == None:
            test_shape = self.live_tetromino.shape
        if test_postion == None:
            test_postion = self.live_tetromino.grid_position

        for local_y, grid_y in enumerate(range(test_postion[1], test_postion[1] + 4)):
            for local_x, grid_x in enumerate(range(test_postion[0], test_postion[0] + 4)): # TODO: Duplicate code from tick function. Find encapsulation method
                tetromino_cell_value = test_shape[-local_y + 3][local_x]
                if tetromino_cell_value != 0: 
                    if grid_x < 0 or grid_y < 0 or grid_x > self.blocks_width or grid_y > self.blocks_height: 
                        return False
                    if grid[grid_y][grid_x] != 0:
                        return False
        return True

    def rotate_tetromino(self, clockwise = True) -> bool:
        if self.live_tetromino.type_index == 4: # O (square) piece doesn't rotate
            return

        loops = 1 if clockwise else 3 # Three rights make a left
        initial_shape = self.live_tetromino.shape
        for _ in range(loops): # This is the sloppy way to turn counter-clockwise. Refactor later
            self.attempt_rotate_tetromino_clockwise()

        if self.check_move_validity(test_shape=self.live_tetromino.shape):
            return True
        # Else we are inside something:
        if clockwise: # Clockwise
            if self.move_tetromino(test_postion=(-1,0)):
                return True
            if self.move_tetromino(test_postion=(0,-2)):
                return True
            if self.move_tetromino(test_postion=(-1,2)):
                return True
        else: # Counter-clockwise
            if self.move_tetromino(test_postion=(1,0)):
                return True
            if self.move_tetromino(test_postion=(1,-1)):
                return True
            if self.move_tetromino(test_postion=(0,2)):
                return True
            if self.move_tetromino(test_postion=(1,2)):
                return True


    def attempt_rotate_tetromino_clockwise(self):
        size = Tetromino.size
        rotated_shape = [[0 for _ in range(size)] for _ in range(size)]
        for x, row in enumerate(self.live_tetromino.shape):
            for y, cell in enumerate(row):
                rotated_shape[y][x] = cell
        for row in rotated_shape:
            row = row.reverse()
        self.live_tetromino.shape = rotated_shape


    def lock_piece(self):
        pos = self.live_tetromino.grid_position
        for local_y, grid_y in enumerate(range(pos[1], pos[1] + 4)):
            for local_x, grid_x in enumerate(range(pos[0], pos[0] + 4)):
                tetromino_cell_value = self.live_tetromino.shape[-local_y + 3][local_x] # Invert y because the origin is in the bottom left of the grid
                if tetromino_cell_value != 0:
                    self.dead_grid[grid_y][grid_x] = tetromino_cell_value

        self.spawn_tetromino()

    def reset_down(self):
        self.down_time_elapsed = 0
        self.moves_while_down = 0
        self.is_down = False

    def moved(self):
        if self.is_down:
            if self.moves_while_down < self.max_moves_while_down:
                self.moves_while_down += 1
                self.down_time_elapsed = 0
            else:
                self.lock_piece()

    def clear_lines(self):
        lines_cleared = 0 
        for y, row in enumerate(self.dead_grid): 
            inverse_y = self.blocks_height - y
            if not 0 in row: # Row is full
                self.dead_grid.pop(y)
                self.dead_grid.insert(self.blocks_height, [0 for element in range(self.blocks_width)])
        
                    
        # TODO: Add animation

    def draw_tetromino(self, grid_position = None, type_index = None):
        # Draw tetromino on top of dead_grid
        if grid_position == None:
            pos = self.live_tetromino.grid_position
        else:
            pos = grid_position
        if type_index != None:
            shape = Tetromino.shapes[type_index]
        else:
            shape = self.live_tetromino.shape
        for local_y, grid_y in enumerate(range(pos[1], pos[1] + 4)):
            y_position = self.blocks_height - grid_y + self.game_y_offset
            y_position *= self.block_size
            for local_x, grid_x in enumerate(range(pos[0], pos[0] + 4)):
                x_position = grid_x + self.game_x_offset 
                x_position *= self.block_size
                tetromino_cell_value = shape[-local_y + 3][local_x] # Invert y because the origin is in the bottom left of the grid
                if tetromino_cell_value != 0:
                    if type_index != None:
                        tetromino_cell_value = type_index
                    self.draw_square(tetromino_cell_value, (x_position, y_position))

    def draw_grid(self):
        if not self.headless:
            self.screen.fill((35,35,35)) # Help the preview pixels to stand out from the black background
            pygame.display.flip()

        grid = copy.deepcopy(self.dead_grid) # Perform deep copy

        # Draw dead_grid
        for y_index, column in enumerate(self.dead_grid):
            y_position = self.blocks_height - y_index + self.game_y_offset
            for x_index, value in enumerate(column): 
                x_position = x_index + self.game_x_offset 
                color_index = self.dead_grid[y_index][x_index]
                pos = (x_position * self.block_size, y_position * self.block_size)
                self.draw_square(color_index, pos)

    def tick(self, delta_time, fps): # Called in main
        if self.is_down:
            self.down_time_elapsed += delta_time
        if self.down_time_elapsed >= self.max_lock_down_time:
            self.down_time_elapsed = 0
            self.lock_piece()
            self.is_down = False

        self.drop_tetromino_by_gravity(fps)
        self.draw_grid()
        self.clear_lines()
        self.draw_border()
        self.draw_tetromino()
        self.draw_next_piece_preview()
                
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
                            tetris.drop_piece()
                        case "HARD_DROP":
                            tetris.drop_piece()
                return handle_tetris_input
            set_input_handler(player.player_id, make_input_handler())
       
    def move_piece_left(self):
        log("LEFT", module="Tetris")
        self.move_tetromino(offset=(-1,0))
        self.moved()

    def move_piece_right(self):
        log("RIGHT", module="Tetris")
        self.move_tetromino(offset=(1,0))
        self.moved()

    def rotate_clockwise(self):
        log("ROTATE_CLOCKWISE", module="Tetris")
        self.rotate_tetromino()
        self.moved()

    def rotate_counterclockwise(self):
        log("ROTATE__COUNTER_CLOCKWISE", module="Tetris")
        self.rotate_tetromino(clockwise=False)
        self.moved()

    def drop_piece(self):
        log("MOVE_DOWN", module="Tetris")
        self.move_tetromino(offset=(0,-1))
        self.moved()

    def hard_drop_piece(self):
        log("HARD_DROP", module="Tetris")
        for _ in range(self.blocks_height):
            self.move_tetromino(offset=(0,-1))
            self.moved()