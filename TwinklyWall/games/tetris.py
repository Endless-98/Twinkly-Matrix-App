# All code in this file must be handwritten! No AI allowed!

# TODO
    # Save piece
    # Piece not locking when it should if rapidly rotating and moving
    # Scoring
        # Combo recognition
        # Perfect clear recognition (for later games)

import sys
import os
import pygame
from pathlib import Path
import numpy
from .tetromino import Tetromino, RandomBag
from logger import log
from game_players import set_player_score_data,get_active_players_for_game, get_game_for_player
from players import set_input_handler
from enum import IntEnum
import copy
import time

class Tetris:
    class Gamemode(IntEnum):
        CLASSIC = 0 # Same rules as the classic NES version
        MODERN = 1 # Follows the rules of Tetris Worlds Marathon. More forgiving. Uses 7-Bag and resetable down-timer

    def __init__(self, canvas, HEADLESS, level, gamemode_selection):
        ### Settings ###
        self.gamemode = self.Gamemode.MODERN
        self.headless = HEADLESS
        self.blocks_width = 10
        self.blocks_height = 25 
        self.block_size = 3
        self.screen = canvas 
        self.play_ceiling = self.screen.get_height() / self.block_size # Only ~ 16.667 visible on matrix with current setup
        self.border_thickness = 2
        self.border_color = (105,105,105)
        self.ghost_opacity = 65
        self.game_x_offset = self.screen.get_width() / self.block_size - self.blocks_width -1
        self.game_y_offset = self.screen.get_height() / self.block_size - self.blocks_height - 1
        self.colors = [(0,0,0,0), (0, 230, 254), (24, 1, 255), (255, 115, 8), (255, 222, 0), (102, 253, 0), (254, 16, 60), (184, 2, 253)]
        self.randomizer = RandomBag(random_style_index=self.gamemode)
        self.dead_grid  = [[0 for element in range(self.blocks_width)] for row in range(self.blocks_height)]
        current_dir = os.path.dirname(os.path.abspath(__file__))
        img_path = os.path.join(current_dir, 'game_over_screen.png')
        self.game_over_image = pygame.image.load(str(img_path)).convert_alpha()

        ### Leveling ###
        self.level = 1
        self.score = 0 # For the scoreboard
        self.points = 0 # Progresses towards goal
        self.total_lines_cleared = 0
        self.combo = 0
        self.drop_interval = 0.0
        self.drop_time_elapsed = 0.0
        self.next_level_goal = 0
        
        match self.gamemode:
            case self.Gamemode.CLASSIC:
                self.level -= 1 # Level 0 is the first level
                self.max_lock_down_time = 0 # Locks the next frame after being down
                self.base_clear_goal = 10
                self.next_level_goal = numpy.min((self.level * self.base_clear_goal + self.base_clear_goal, numpy.max((100, self.level * self.base_clear_goal - 50))))
                self.lines_cleared = 0
                print(f"Next level goal: {self.next_level_goal}")
                self.NES_fps = 60.0988 # Used to calculate drop interval to match up with exact NES speeds
                self.score_reward = [0,40,100,300,1200] # Index: num lines cleared at once
                self.soft_drop_streak = 0 # Every cell that is soft-dropped adds a point as long as you don't release before the piece locks
                self.is_soft_dropping = False
                
            case self.Gamemode.MODERN:
                self.base_goal = 5
                self.base_speed = 0.8
                self.speed_increment = 0.007
                self.points_reward = [0,1,3,5,8] # Index: num lines cleared at once
                self.gravity = 0
                self.max_moves_while_down = 15
                self.moves_while_down = 0
                self.down_time_elapsed = 0.0
                self.next_level_goal = self.base_goal * self.level
                self.max_lock_down_time = 0.500
       
        self.calc_drop_speed() # Also called each time we level up
        self.players = get_active_players_for_game('tetris')
        self.live_tetromino = None
        self.is_down = False
        self.is_playing = True

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
        type_index = self.randomizer.next_piece
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
        elif is_soft_drop and self.gamemode == self.Gamemode.MODERN:
            self.award_score(1)
        
        
        if move_succeeded and self.gamemode == self.Gamemode.CLASSIC:
            if self.is_soft_dropping:
                self.soft_drop_streak += 1
            else:
                self.soft_drop_streak = 0


        # Require two blocks air to reset down
        if self.is_down and self.check_move_validity(test_postion=(self.live_tetromino.grid_position[0], self.live_tetromino.grid_position[1] -2)):
            self.is_down = False
            self.reset_down() 
        # One block air is enough to pause
        if self.check_move_validity(test_postion=(self.live_tetromino.grid_position[0], self.live_tetromino.grid_position[1] -1)):
            self.is_down = False

        return move_succeeded
        

    def hard_drop_tetromino(self, was_player_called = False):
        for _ in range(self.blocks_height):
            if self.drop_tetromino() and was_player_called:
                self.award_score(2)
        self.lock_piece()

    def spawn_tetromino(self):
        piece_type = self.randomizer.pull_piece()
        size = self.get_size(piece_type)

        self.live_tetromino = Tetromino(piece_type, grid_position=((self.blocks_width - size) // 2, self.blocks_height - size))
   
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
        print("Lock piece")
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

        if self.gamemode == self.Gamemode.CLASSIC:
            self.award_score(self.soft_drop_streak)
            self.soft_drop_streak = 0
            
        self.spawn_tetromino()
        self.is_down = False
        self.clear_lines()


    def reset_down(self):
        self.down_time_elapsed = 0
        self.moves_while_down = 0
        self.is_down = False
        print("Reset down!")

    def moved(self, wants_to_lock = False):
        if self.is_down:
            if self.moves_while_down < self.max_moves_while_down:
                self.moves_while_down += 1
                self.down_time_elapsed = 0
                print(f"Down moves left: {self.moves_while_down}")
            else:
                self.lock_piece()

    def calc_drop_speed(self): # TODO: Call every level change
        match self.gamemode:
            case self.Gamemode.MODERN:
                self.drop_interval = numpy.power((self.base_speed - ((self.level - 1) * self.speed_increment)), self.level - 1)
                
            case self.Gamemode.CLASSIC:
                frames_per_drop = 48
                match self.level: # Values match NES Marathon mode
                    case 0:
                        frames_per_drop = 48 
                    case 1:
                        frames_per_drop = 43 
                    case 2:
                        frames_per_drop = 38  
                    case 3: 
                        frames_per_drop = 33
                    case 4: 
                        frames_per_drop = 28
                    case 5: 
                        frames_per_drop = 23
                    case 6: 
                        frames_per_drop = 18
                    case 7: 
                        frames_per_drop = 13
                    case 8: 
                        frames_per_drop = 8
                    case 9: 
                        frames_per_drop = 6
                    case level if 10 <= level < 13: 
                        frames_per_drop = 5
                    case level if 13 <= level < 16: 
                        frames_per_drop = 4
                    case level if 16 <= level < 19: 
                        frames_per_drop = 3
                    case level if 19 <= level < 28: 
                        frames_per_drop = 2
                    case level if 29 <= level: 
                        frames_per_drop = 1

                self.drop_interval = frames_per_drop / self.NES_fps
                if self.is_soft_dropping:
                    self.drop_interval /= 2

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
                    # print("Line clear")
                    pygame.display.flip()

            self.total_lines_cleared += lines_cleared
                        
            # TODO: Add animation
            self.score_lines(lines_cleared)
            keep_clearing = lines_cleared > 0

    def award_score(self, score_amount):
        if score_amount <= 0:
            return
        
        print(f"Scored {score_amount} points. Total: {self.score}")

        self.score += score_amount
        self.update_scoreboard()

        # print(f"Score: {self.score}")

    def score_lines(self, lines_cleared):
        if lines_cleared <= 0:
            return
        
        match self.gamemode:
            case self.Gamemode.MODERN:
                points_award = self.points_reward[lines_cleared] 
                self.points += points_award
                score_award = (points_award * 100) * self.level
                if score_award > 0:
                    self.award_score(score_award)
                if points_award > 0:
                    print(f"Points: {self.points}: Goal: {self.next_level_goal}")
                if self.points >= self.next_level_goal:
                    self.level_up()

            case self.Gamemode.CLASSIC:
                score_award = self.score_reward[lines_cleared] * self.level + 1
                self.award_score(score_award)
                self.lines_cleared += lines_cleared
                if self.lines_cleared >= self.next_level_goal:
                    self.level_up()
                    self.lines_cleared = 0


    def level_up(self):
        self.level += 1
        
        match self.gamemode:
            case self.Gamemode.MODERN:
                self.points -= self.next_level_goal
                self.next_level_goal = self.base_goal * self.level
            case self.Gamemode.CLASSIC:
                self.next_level_goal = 10

        self.update_scoreboard()
        self.calc_drop_speed()
        log(f"Level up: {self.level}")
        print(f"Level up: {self.level}")

    def game_over(self):
        self.is_playing = False
        print("Game over!")
        print(f"Score: {self.score}")
        print(f"Level: {self.level}")

    def draw_game_over_frame(self):
        self.screen.fill((0, 0, 0))
        image_height = self.blocks_height * self.block_size / 1.3
        image_width = self.blocks_width * self.block_size
        scaled_image = pygame.transform.scale(self.game_over_image, (image_width, image_height))
        scaled_rect = scaled_image.get_rect()
        scaled_rect.center = ((self.screen.get_width() // 2) + image_width / 1.2, self.screen.get_height() - (scaled_rect.height // 2))
        self.screen.blit(scaled_image, scaled_rect)
        pygame.display.update()

    def tick(self, delta_time, fps): # Called in main
        if not self.is_playing:
            self.draw_game_over_frame()
            return

        match self.gamemode:
            case self.Gamemode.MODERN:
                if self.is_down:
                    self.down_time_elapsed += delta_time
                    print(f"Down time elapsed: {self.down_time_elapsed}")

                if self.down_time_elapsed >= self.max_lock_down_time:
                    self.hard_drop_tetromino()
                    self.down_time_elapsed = 0
                    self.is_down = False
            case self.Gamemode.CLASSIC:
                if self.is_down:
                    self.lock_piece()

        self.drop_time_elapsed += delta_time
        if self.drop_time_elapsed >= self.drop_interval:
            self.drop_tetromino()
            self.drop_time_elapsed = 0
    
        self.draw_grid()
        self.draw_ghost_piece()
        self.draw_border()
        self.draw_tetromino()
        self.draw_next_piece_preview()

        if self.gamemode == self.Gamemode.CLASSIC:
            return

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

    def drop_piece(self, is_pressed):
        match self.gamemode:
            case self.Gamemode.MODERN:
                if not is_pressed:
                    return
                
                self.drop_tetromino()       
                self.moved(wants_to_lock=True)
            case self.Gamemode.CLASSIC:
                self.is_soft_dropping = is_pressed
                # print(f"Is soft dropping: {is_pressed}")
                self.calc_drop_speed()
                if not is_pressed:
                    self.soft_drop_streak = 0

    def hard_drop_piece(self):
        if self.gamemode == self.Gamemode.CLASSIC:
            return

        self.hard_drop_tetromino(was_player_called=True)
        self.moved(wants_to_lock=True)