# All code in this file must be handwritten! No AI allowed!

# TODO
    # Save piece
    # Tidy piece preview
    # BUG: Piece stopping in wall (possibly when pressing down?)
    # Scoring
        # Soft drop score
        # Scoring system, including Back-to-Back recognition rules
        # Combo recognition
        # Perfect clear recognition (for later games)

import sys
import os
import pygame
from pathlib import Path
import numpy
import random
from .tetromino import Tetromino, Random_Bag
from logger import log
from game_players import set_player_score_data,get_active_players_for_game, get_game_for_player
from players import set_input_handler
import copy
import time

class Tetris:
    def __init__(self, canvas, HEADLESS, level):
        ### Settings ###
        self.headless = HEADLESS
        self.blocks_width = 10
        self.blocks_height = 25 
        self.block_size = 3
        self.border_thickness = 2
        self.border_color = (105,105,105)
        self.screen = canvas
        self.ghost_opacity = 65
        
        ### Leveling ###
        self.level = 1
        self.score = 0 # For the scoreboard
        self.points = 0 # Progresses towards goal
        self.base_goal = 5
        self.total_lines_cleared = 0
        self.next_level_goal = self.base_goal * self.level
        self.play_ceiling = self.screen.get_height() / self.block_size # Only ~ 16.667 visible on matrix with current setup
        self.speed_increment = 0.007
        self.base_speed = 0.8
        self.combo = 0
        self.points_reward = [0,1,3,5,8] # Index: num lines cleared at once
        self.was_last_score_tetris = False
        current_dir = os.path.dirname(os.path.abspath(__file__))
        img_path = os.path.join(current_dir, 'game_over.png')
        print(img_path)
        # game_over_path = str(games_filepath) + "/game_over_screen.png"
        # game_over_img_path = sys.argv[0] + "/games/game_over_screen.png"
        self.game_over_image = pygame.image.load(str(img_path)).convert_alpha()
        # self.game_over_image = pygame.image.load(abs_script_path).convert_alpha()
        # self.game_over_image = pygame.image.load("./game_over_screen.png").convert_alpha()

        self.players = get_active_players_for_game('tetris')
        self.live_tetromino = None
        self.is_playing = True
        self.hard_drop_cooldown = 0.0
        self.hard_drop_time_elapsed = 0.0
        self.drop_interval = 0.0
        self.drop_time_elapsed = 0.0
        self.max_lock_down_time = 0.500
        self.down_time_elapsed = 0.0
        self.gravity = 0
        self.calc_gravity() # Also called each time we level up
        self.is_down = False
        self.max_moves_while_down = 15
        self.moves_while_down = 0
        self.colors = [(0,0,0,0), (0, 230, 254), (24, 1, 255), (255, 115, 8), (255, 222, 0), (102, 253, 0), (254, 16, 60), (184, 2, 253)]
        self.bag = Random_Bag()

        self.game_x_offset = self.screen.get_width() / self.block_size - self.blocks_width -1
        self.game_y_offset = self.screen.get_height() / self.block_size - self.blocks_height - 1
        self.dead_grid  = [[0 for element in range(self.blocks_width)] for row in range(self.blocks_height)]
        self.spawn_tetromino()

    def get_size(self, type_index) -> int:
        size = 4 if type_index == 4 or type_index == 1 else 3
        return size

    def draw_square(self, color_index, position, opacity = 255):
        color = self.colors[color_index]
        
        if len(color) <= 3:
            color = (*color, opacity)
        
        pygame.draw.rect(self.screen, color, (position[0], position[1], self.block_size, self.block_size))
    
    def draw_border(self):
        x_left = int(self.game_x_offset * self.block_size) - self.border_thickness
        x_right = int(self.game_x_offset * self.block_size + (self.blocks_width * self.block_size))
        pygame.draw.rect(self.screen, self.border_color, (x_left, 0, self.border_thickness, 1000,))
        pygame.draw.rect(self.screen, self.border_color, (x_right, 0, self.border_thickness, 1000,))

    def draw_next_piece_preview(self):
        type_index = self.bag.next_piece
        thickness = self.block_size + 9
        x_left = int(self.game_x_offset * self.block_size) - thickness - self.border_thickness + 1 
        pygame.draw.rect(self.screen, self.border_color, (x_left, 0, thickness, thickness,))
        
        self.draw_tetromino(grid_position=(-4,13), type_index=type_index)

    def draw_ghost_piece(self):
        type_index = self.live_tetromino.type_index
        pos = self.live_tetromino.grid_position
        rotation = self.live_tetromino.rotation
        for y in range(pos[1], -self.get_size(type_index), -1): 
            pos = (pos[0], y)
            if not self.check_move_validity(pos):
                pos = (pos[0], y + 1)
                break
        self.draw_tetromino(grid_position=pos, opacity=self.ghost_opacity)

    def draw_tetromino(self, grid_position = None, type_index = None, opacity = 255):
        # Draw tetromino on top of dead_grid
        if grid_position == None:
            pos = self.live_tetromino.grid_position
        else:
            pos = grid_position
        if type_index != None:
            shape = Tetromino.shapes[type_index]
        else:
            shape = self.live_tetromino.shape
            type_index = self.live_tetromino.type_index
        size = self.get_size(type_index)
        for local_y, grid_y in enumerate(range(pos[1], pos[1] + size)):
            y_position = self.blocks_height - grid_y + self.game_y_offset
            y_position *= self.block_size
            for local_x, grid_x in enumerate(range(pos[0], pos[0] + size)):
                x_position = grid_x + self.game_x_offset 
                x_position *= self.block_size
                tetromino_cell_value = shape[-local_y + size -1][local_x] # Invert y because the origin is in the bottom left of the grid
                if tetromino_cell_value != 0:
                    if type_index != None:
                        tetromino_cell_value = type_index
                    self.draw_square(tetromino_cell_value, (x_position, y_position), opacity)

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

    def drop_tetromino(self, is_soft_drop = False) -> bool:
        move_succeeded = True
        if not self.move_tetromino(offset=(0, -1)):
            self.is_down = True
            move_succeeded = False
        elif is_soft_drop:
            self.award_score(1)

        if self.check_move_validity(test_postion=(self.live_tetromino.grid_position[0], self.live_tetromino.grid_position[1] -1)):
            self.is_down = False

        if not self.is_down:
            self.reset_down()

        return move_succeeded

    def hard_drop_tetromino(self, was_player_called = False):
        for _ in range(self.blocks_height):
            if self.drop_tetromino() and was_player_called:
                self.award_score(2)
        self.lock_piece()

    def spawn_tetromino(self):
        piece_type = self.bag.pull_piece()
        size = self.get_size(piece_type)

        self.live_tetromino = Tetromino(piece_type, grid_position=((self.blocks_width - size) // 2, self.blocks_height - size))
        # self.live_tetromino = Tetromino(piece_type, grid_position=(0, self.blocks_height - size))
   
    def move_tetromino(self, offset:()) -> bool:
        new_position = (self.live_tetromino.grid_position[0] + offset[0], self.live_tetromino.grid_position[1] + offset[1])

        if not self.check_move_validity(test_postion=new_position):
            return False
        self.live_tetromino.grid_position = new_position
        return True

    def check_move_validity(self, test_postion : () = None) -> bool:
        grid = self.dead_grid

        if test_postion == None:
            test_postion = self.live_tetromino.grid_position
        size = self.get_size(self.live_tetromino.type_index)
        for local_y, grid_y in enumerate(range(test_postion[1], test_postion[1] + size)):
            for local_x, grid_x in enumerate(range(test_postion[0], test_postion[0] + size)): # TODO: Duplicate code from tick function. Find encapsulation method
                tetromino_cell_value = self.live_tetromino.shape[-local_y + size - 1][local_x]
                if tetromino_cell_value != 0: 
                    if grid_x < 0 or grid_y < 0 or grid_x >= self.blocks_width or grid_y > self.blocks_height: 
                        return False
                    if grid[grid_y][grid_x] != 0:
                        return False
        return True

    def rotate_tetromino(self, clockwise = True) -> bool:
        type_index = self.live_tetromino.type_index
        if type_index == 4: # O (square) piece doesn't rotate
            return True

        loops = 1 if clockwise else 3 # Three rights make a left
        initial_shape = self.live_tetromino.shape
        initial_rot = self.live_tetromino.rotation
        desired_rot = (initial_rot + loops) % 4
        for _ in range(loops): # This is the sloppy way to turn counter-clockwise. Refactor later
            self.rotate_shape_clockwise()

        if self.check_move_validity():
            self.live_tetromino.rotation = desired_rot
            return True

        piece_group = 1 if type_index == 1 else 0
        for offset in Tetromino.kick_offsets[piece_group][clockwise][desired_rot]:
            if self.move_tetromino(offset):
                return True

        self.live_tetromino.shape = initial_shape
        self.live_tetromino.rotation = initial_rot  
        return False

    def rotate_shape_clockwise(self):
        self.live_tetromino.shape = [list(reversed(element)) for element in zip(*self.live_tetromino.shape)]

    def lock_piece(self):
        self.clear_lines()
        self.move_tetromino(offset=(0, -1))

        pos = self.live_tetromino.grid_position
        size = self.get_size(self.live_tetromino.type_index)

        # There is probably a "Pythonic" way to make this more concise
        for local_y, grid_y in enumerate(range(pos[1], pos[1] + size)):
            for local_x, grid_x in enumerate(range(pos[0], pos[0] + size)):
                tetromino_cell_value = self.live_tetromino.shape[-local_y + size - 1][local_x] # Invert y because the origin is in the bottom left of the grid
                if tetromino_cell_value != 0:
                    self.dead_grid[grid_y][grid_x] = tetromino_cell_value
                    if grid_y >= self.play_ceiling:
                        self.game_over()

        self.spawn_tetromino()
        self.is_down = False

    def reset_down(self):
        self.down_time_elapsed = 0
        self.moves_while_down = 0
        self.is_down = False

    def moved(self, wants_to_lock = False):
        if self.is_down:
            if self.moves_while_down < self.max_moves_while_down:
                self.moves_while_down += 1
                self.down_time_elapsed = 0
            else:
                self.lock_piece()

    def calc_gravity(self): # TODO: Call every level change
        self.drop_interval = numpy.power((self.base_speed - ((self.level - 1) * self.speed_increment)), self.level - 1)

    def clear_lines(self):
        keep_clearing = True
        while keep_clearing:
            lines_cleared = 0 
            for y, row in enumerate(self.dead_grid): 
                inverse_y = self.blocks_height - y
                if not 0 in row: # Row is full
                    self.dead_grid.pop(y)
                    self.dead_grid.insert(self.blocks_height, [0 for element in range(self.blocks_width)])
                    lines_cleared += 1
                    print("Line clear")
            self.total_lines_cleared += lines_cleared
                        
            # TODO: Add animation
            self.score_lines(lines_cleared)
            keep_clearing = lines_cleared > 0

    def award_score(self, score_amount):
        if score_amount <= 0:
            return

        self.score += score_amount
        self.update_scoreboard()

        print(f"Score: {self.score}")

    def score_lines(self, lines_cleared):
        points_award = self.points_reward[lines_cleared] 
        self.points += points_award
        score_award = (points_award * 100) * self.level
        if score_award > 0:
            self.award_score(score_award)

        if points_award > 0:
            print(f"Points: {self.points}: Goal: {self.next_level_goal}")
        if self.points >= self.next_level_goal:
            self.level_up()

    def level_up(self):
        self.level += 1
        self.points -= self.next_level_goal
        self.next_level_goal = self.base_goal * self.level
        self.update_scoreboard()
        self.calc_gravity()

        log(f"Level up: {self.level}")
        print(f"Level up: {self.level}")

    def game_over(self):
        self.is_playing = False
        print("Game over!")
        print(f"Score: {self.score}")
        print(f"Level: {self.level}")


    def tick(self, delta_time, fps): # Called in main
        if not self.is_playing:
            self.screen.fill((0, 0, 0))
            image_height = self.blocks_height * self.block_size / 1.3
            image_width = self.blocks_width * self.block_size
            scaled_image = pygame.transform.scale(self.game_over_image, (image_width, image_height))
            scaled_rect = scaled_image.get_rect()
            scaled_rect.center = ((self.screen.get_width() // 2) + image_width / 1.2, self.screen.get_height() - (scaled_rect.height // 2))
            self.screen.blit(scaled_image, scaled_rect)
            pygame.display.update()
            return
        
        self.drop_time_elapsed += delta_time
        if self.drop_time_elapsed >= self.drop_interval:
            self.drop_tetromino()
            self.clear_lines()
            self.drop_time_elapsed = 0
            
        if self.is_down:
            self.down_time_elapsed += delta_time
        if self.down_time_elapsed >= self.max_lock_down_time:
            self.down_time_elapsed = 0
            self.hard_drop_tetromino()
            self.is_down = False

        self.draw_grid()
        self.draw_ghost_piece()
        self.draw_border()
        self.draw_tetromino()
        self.draw_next_piece_preview()
                
    def begin_play(self): # Called in main
        self.bind_input(self)   

    def update_scoreboard(self):
        for player in self.players:
            set_player_score_data(player.player_id, self.score, self.level, self.total_lines_cleared)

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
                            tetris.hard_drop_piece()
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
        self.drop_tetromino()
        self.moved(wants_to_lock=True)

    def hard_drop_piece(self):
        log("HARD_DROP", module="Tetris")
        self.hard_drop_tetromino(was_player_called=True)
        self.moved(wants_to_lock=True)