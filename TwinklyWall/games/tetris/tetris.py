# All code in this file must be handwritten! No AI allowed!

# TODO
    # Save piece
    # Piece not locking when it should if rapidly rotating and moving
    # Scoring
        # Combo recognition
        # Perfect clear recognition (for later games)

    ### Get an AI evaluation of my codebase, and use it to ensure perfect commercial accuracy ###
    # Docstrings for each function
    # Remove all magic numbers by abstracting them into a constants file.
    # Apply OOP principles
    # Properly us ENUMs, instead of passing in indices and converting them to ENUMs
    # Abstract out the ENUMs that are nested inside of other classes to their own file.
    # Better comments explaining thought processes
    # Better variable names

import os
import pygame
import numpy
from .tetromino import Tetromino, RandomBag
from game_players import set_player_score_data, get_active_players_for_game
from players import set_input_handler
from .enums import Gamemode
from .constants import (
    GAME_NAME, GRID_WIDTH, GRID_HEIGHT, GRID_PIXEL_SIZE, 
    BORDER_COLOR, BORDER_THICKNESS,
    RGBA_OFF_PIXEL_GRAY, RGB_WHITE, RGB_BLACK, RGBA_INVISIBLE_BLACK, FULL_OPACITY_ALPHA,
    TETROMINO_GHOST_ALPHA, TETROMINO_I_CYAN, TETROMINO_O_YELLOW, TETROMINO_T_MAGENTA, 
    TETROMINO_S_GREEN, TETROMINO_Z_RED, TETROMINO_J_DARK_BLUE, TETROMINO_L_ORANGE,
    TETROMINO_MAX_GRID_SIZE,
    LINE_FADE_TIME_SECONDS, GAME_OVER_FILENAME, CLASSIC_FIRST_LEVEL_GOAL_FLOOR,
    CLASSIC_NEXT_LEVEL_BASE_GOAL, CLASSIC_NES_FPS, CLASSIC_START_LEVEL_INDEX, CLASSIC_LINES_CLEARED_SCORE_REWARD,
    CLASSIC_POINTS_PER_SOFT_DROP_STEP, CLASSIC_SOFT_DROP_SPEED_DIVISOR, CLASSIC_LEVEL_INDEX_SCORE_OFFSET,
    MODERN_MAX_MOVES_WHILE_DOWN, MODERN_BASE_DROP_SPEED, MODERN_SPEED_MULTIPLIER, MODERN_MAX_DOWN_TIME_SECONDS,
    MODERN_START_LEVEL_INDEX, MODERN_LINES_CLEARED_POINTS_REWARD, MODERN_NEXT_LEVEL_BASE_GOAL, MODERN_RESET_DOWN_GAP,
    MODERN_POINTS_TO_SCORE_MULTPLIER,
)

class Tetris:
    def __init__(self, canvas, HEADLESS, level, gamemode_selection):
        ### Settings ###
        self.gamemode = Gamemode(gamemode_selection)
        self.headless = HEADLESS
        self.screen = canvas 
        self.game_over_grid_ceiling = self.screen.get_height() / GRID_PIXEL_SIZE
        self.screen_grid_height = int(numpy.round(self.game_over_grid_ceiling))
        self.game_x_offset = (self.screen.get_width() / GRID_PIXEL_SIZE - GRID_WIDTH) - 1 # TODO : Determine why the -1 is needed
        self.game_y_offset = (self.screen.get_height() / GRID_PIXEL_SIZE - GRID_HEIGHT) - 1 # TODO : Determine why the -1 is needed
        self.colors = [RGB_BLACK, TETROMINO_I_CYAN, TETROMINO_O_YELLOW, TETROMINO_T_MAGENTA, 
                       TETROMINO_S_GREEN, TETROMINO_Z_RED, TETROMINO_J_DARK_BLUE, TETROMINO_L_ORANGE] # TODO : Move to an enum
        self.randomizer = RandomBag(random_style_index=self.gamemode)
        self.dead_grid  = [[0 for element in range(GRID_WIDTH)] for row in range(GRID_HEIGHT)]
        current_dir = os.path.dirname(os.path.abspath(__file__))
        img_path = os.path.join(current_dir, 'assets', GAME_OVER_FILENAME)
        self.game_over_image = pygame.image.load(str(img_path)).convert_alpha()
        self.fading_lines = [] # Structure: [ (line_index 1, alpha 1.0, time_elapsed 0.0) ] # TODO : Objectify so that structure is built-in

        ### Leveling ###
        self.score = 0 # For the scoreboard
        self.points = 0 # Progresses towards goal
        self.total_lines_cleared = 0
        self.combo = 0
        self.drop_interval = 0.0
        self.drop_time_elapsed = 0.0
        self.next_level_goal = 0
        
        self.__initialize_gamemode_specific_parameters()
       
        self.__calc_drop_speed() # Also called each time we level up
        self.players = get_active_players_for_game(GAME_NAME)
        self.live_tetromino = None
        self.is_down = False
        self.is_playing = True

        self.__spawn_tetromino()

    def __initialize_gamemode_specific_parameters(self):
        match self.gamemode:
            case Gamemode.CLASSIC:
                self.level_index = CLASSIC_START_LEVEL_INDEX
                # This equation comes from the NES Tetris equation for determining the first level goal. It only happens at the start of the game
                self.next_level_goal = numpy.min(
                    (self.level_index * CLASSIC_NEXT_LEVEL_BASE_GOAL + CLASSIC_NEXT_LEVEL_BASE_GOAL,
                        numpy.max((CLASSIC_FIRST_LEVEL_GOAL_FLOOR, 
                                self.level_index * CLASSIC_NEXT_LEVEL_BASE_GOAL - CLASSIC_FIRST_LEVEL_GOAL_FLOOR))))
                self.lines_cleared = 0
                self.soft_drop_streak = 0 # Every cell that is soft-dropped adds a point as long as you don't release before the piece locks
                self.is_soft_dropping = False # Set by player input, equates to whether player is holding drop button
                
            case Gamemode.MODERN:
                self.level_index = MODERN_START_LEVEL_INDEX
                self.gravity = 0
                self.moves_while_down = 0
                self.down_time_elapsed = 0.0
                self.next_level_goal = MODERN_NEXT_LEVEL_BASE_GOAL * self.level_index

    def __get_size(self, type_index) -> int: # TODO : Rework this function
        size = 4 if type_index == 4 or type_index == 1 else 3 # TODO : Move magic number to constants
        return size

    def __draw_square(self, color_index, position, opacity = FULL_OPACITY_ALPHA):
        color = self.colors[color_index]
        
        if len(color) == 3: # If color is in RGB form
            color = (*color, opacity) # Add opacity
        
        pygame.draw.rect(self.screen, color, (position[0], position[1], GRID_PIXEL_SIZE, GRID_PIXEL_SIZE))
    
    def __draw_border(self):
        x_left = int(self.game_x_offset * GRID_PIXEL_SIZE) - BORDER_THICKNESS
        x_right = int(self.game_x_offset * GRID_PIXEL_SIZE + (GRID_WIDTH * GRID_PIXEL_SIZE))
        pygame.draw.rect(self.screen, BORDER_COLOR, (x_left, 0, BORDER_THICKNESS, GRID_HEIGHT * GRID_PIXEL_SIZE,))
        pygame.draw.rect(self.screen, BORDER_COLOR, (x_right, 0, BORDER_THICKNESS, GRID_HEIGHT * GRID_PIXEL_SIZE,))

    def __draw_next_piece_preview(self): # TODO : Get live piece size instead of TETROMINO_MAX_GRID_SIZE
        type_index = self.randomizer.next_piece
        thickness = GRID_PIXEL_SIZE * TETROMINO_MAX_GRID_SIZE
        x_left = int(self.game_x_offset * GRID_PIXEL_SIZE) - thickness - BORDER_THICKNESS
        pygame.draw.rect(self.screen, BORDER_COLOR, (x_left, 0, thickness, thickness)) 
        
        self.__draw_tetromino(grid_position=(0 - TETROMINO_MAX_GRID_SIZE, self.screen_grid_height - TETROMINO_MAX_GRID_SIZE), type_index=type_index)

    def __draw_ghost_piece(self): # TODO : Write comment explaining this
        type_index = self.live_tetromino.type_index
        pos = self.live_tetromino.grid_position
        for y in range(pos[1], -self.__get_size(type_index), -1): 
            pos = (pos[0], y)
            if not self.__check_move_validity(pos):
                pos = (pos[0], y + 1)
                break
        self.__draw_tetromino(grid_position=pos, opacity=TETROMINO_GHOST_ALPHA)

    def __draw_tetromino(self, grid_position = None, type_index = None, opacity = FULL_OPACITY_ALPHA):
        '''
        Docstring for draw_tetromino
        
        :param self: Description
        :param grid_position: Description
        :param type_index: Description
        :param opacity: Description
        '''
        
        # Draw tetromino on top of dead_grid
        if grid_position is None:
            pos = self.live_tetromino.grid_position
        else:
            pos = grid_position
        if type_index is not None:
            shape = Tetromino.shapes[type_index]
        else:
            shape = self.live_tetromino.shape
            type_index = self.live_tetromino.type_index
        size = self.__get_size(type_index)
        for local_y, grid_y in enumerate(range(pos[1], pos[1] + size)):
            y_position = GRID_HEIGHT - grid_y + self.game_y_offset
            y_position *= GRID_PIXEL_SIZE
            for local_x, grid_x in enumerate(range(pos[0], pos[0] + size)):
                x_position = grid_x + self.game_x_offset 
                x_position *= GRID_PIXEL_SIZE
                tetromino_cell_value = shape[-local_y + size -1][local_x] # Invert y because the origin is in the bottom left of the grid
                if tetromino_cell_value != 0:
                    if type_index is not None:
                        tetromino_cell_value = type_index
                    self.__draw_square(tetromino_cell_value, (x_position, y_position), opacity)

    def __draw_grid(self):
        if not self.headless:
            self.screen.fill(RGBA_OFF_PIXEL_GRAY) # Help the preview pixels to stand out from the black background
            pygame.display.flip()
        else:
            self.screen.fill(RGBA_INVISIBLE_BLACK)

        # Draw dead_grid
        for y_index, column in enumerate(self.dead_grid):
            y_position = GRID_HEIGHT - y_index + self.game_y_offset
            for x_index, value in enumerate(column): 
                x_position = x_index + self.game_x_offset 
                color_index = self.dead_grid[y_index][x_index]
                pos = (x_position * GRID_PIXEL_SIZE, y_position * GRID_PIXEL_SIZE)
                self.__draw_square(color_index, pos)

    def __drop_tetromino(self, is_soft_drop = False) -> bool:
        move_succeeded = True

        if not self.__move_tetromino(offset=(0, -1)):
            self.is_down = True
            move_succeeded = False

        elif is_soft_drop and self.gamemode == Gamemode.MODERN:
            self.__award_score(CLASSIC_POINTS_PER_SOFT_DROP_STEP)
        
        if move_succeeded and self.gamemode == Gamemode.CLASSIC:
            if self.is_soft_dropping:
                self.soft_drop_streak += 1
            else:
                self.soft_drop_streak = 0

        # Require two blocks air to reset down
        if self.is_down and self.__check_move_validity(test_position=(self.live_tetromino.grid_position[0], self.live_tetromino.grid_position[1] - MODERN_RESET_DOWN_GAP)):
            self.is_down = False
            self.__reset_down() 
        # One block air is enough to pause
        if self.__check_move_validity(test_position=(self.live_tetromino.grid_position[0], self.live_tetromino.grid_position[1] -1)): # Offset one block down. Is -1 a magic number?
            self.is_down = False

        return move_succeeded

    def __hard_drop_tetromino(self, was_player_called = False):
        for _ in range(GRID_HEIGHT):
            if self.__drop_tetromino() and was_player_called:
                self.__award_score(2)
        self.__lock_piece()

    def __spawn_tetromino(self):
        piece_type = self.randomizer.pull_piece()
        size = self.__get_size(piece_type)

        self.live_tetromino = Tetromino(piece_type, grid_position=((GRID_WIDTH - size) // 2, GRID_HEIGHT - size)) # TODO : Magic number?
   
    def __move_tetromino(self, offset) -> bool:
        new_position = (self.live_tetromino.grid_position[0] + offset[0], self.live_tetromino.grid_position[1] + offset[1])

        if not self.__check_move_validity(test_position=new_position):
            return False
        self.live_tetromino.grid_position = new_position
        return True

    def __check_move_validity(self, test_position) -> bool:
        grid = self.dead_grid

        if test_position is None:
            test_position = self.live_tetromino.grid_position

        size = self.__get_size(self.live_tetromino.type_index)

        for local_y, grid_y in enumerate(range(test_position[1], test_position[1] + size)):
            for local_x, grid_x in enumerate(range(test_position[0], test_position[0] + size)):
                tetromino_cell_value = self.live_tetromino.shape[-local_y + size - 1][local_x]
                if tetromino_cell_value != 0: 
                    if grid_x < 0 or grid_y < 0 or grid_x >= GRID_WIDTH or grid_y > GRID_HEIGHT: 
                        return False
                    if grid[grid_y][grid_x] != 0:
                        return False
                    
        return True

    def __rotate_tetromino(self, clockwise = True) -> bool:
        type_index = self.live_tetromino.type_index
        if type_index == 4: # O (square) piece doesn't rotate # TODO : Make Enum for type_index
            return True

        loops = 1 if clockwise else 3 # Three rights make a left
        initial_shape = self.live_tetromino.shape
        initial_rot = self.live_tetromino.rotation
        desired_rot = (initial_rot + loops) % 4 # TODO : Make Enum for rotation

        for _ in range(loops):
            self.__rotate_shape_clockwise()

        if self.__check_move_validity(self.live_tetromino.grid_position):
            self.live_tetromino.rotation = desired_rot
            return True

        piece_group = 1 if type_index == 1 else 0
        for offset in Tetromino.kick_offsets[piece_group][clockwise][desired_rot]:
            if self.__move_tetromino(offset):
                return True

        self.live_tetromino.shape = initial_shape
        self.live_tetromino.rotation = initial_rot  
        return False

    def __rotate_shape_clockwise(self):
        self.live_tetromino.shape = [list(reversed(element)) for element in zip(*self.live_tetromino.shape)]

    def __lock_piece(self):
        self.__move_tetromino(offset=(0, -1))
        pos = self.live_tetromino.grid_position
        size = self.__get_size(self.live_tetromino.type_index)

        for local_y, grid_y in enumerate(range(pos[1], pos[1] + size)):
            for local_x, grid_x in enumerate(range(pos[0], pos[0] + size)):
                tetromino_cell_value = self.live_tetromino.shape[-local_y + size - 1][local_x] # Invert y because the origin is in the bottom left of the grid
                if tetromino_cell_value != 0:
                    self.dead_grid[grid_y][grid_x] = tetromino_cell_value
                    if grid_y >= self.game_over_grid_ceiling:
                        self.__game_over()

        if self.gamemode == Gamemode.CLASSIC:
            self.__award_score(self.soft_drop_streak)
            self.soft_drop_streak = 0
            
        self.__spawn_tetromino()
        self.is_down = False
        self.__clear_lines()

    def __reset_down(self):
        self.down_time_elapsed = 0
        self.moves_while_down = 0
        self.is_down = False

    def __moved(self, wants_to_lock = False):
        if self.is_down:
            if self.moves_while_down < MODERN_MAX_MOVES_WHILE_DOWN:
                self.moves_while_down += 1
                self.down_time_elapsed = 0
            else:
                self.__lock_piece()

    def __calc_drop_speed(self):
        match self.gamemode:
            case Gamemode.MODERN: # This algorithm is used by Tetris Worlds to calculate how the drop interval decreases by level
                self.drop_interval = numpy.power((MODERN_BASE_DROP_SPEED - ((self.level_index - 1) * MODERN_SPEED_MULTIPLIER)), self.level_index - 1)
                
            case Gamemode.CLASSIC:
                frames_per_drop = 48 # TODO : Move magic number to constants
                match self.level_index: # Values match NES Marathon mode 
                    # TODO : Refactor with enum in constants file
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

                self.drop_interval = frames_per_drop / CLASSIC_NES_FPS
                if self.is_soft_dropping:
                    self.drop_interval /= CLASSIC_SOFT_DROP_SPEED_DIVISOR

    def __clear_lines(self):
        keep_clearing = True
        while keep_clearing:
            lines_cleared = 0 
            for y, row in enumerate(self.dead_grid): 
                if 0 not in row: # Row is full
                    self.dead_grid.pop(y)
                    self.dead_grid.insert(GRID_HEIGHT, [0 for element in range(GRID_WIDTH)])
                    lines_cleared += 1
                    self.fading_lines.append((y, 1.0, 0.0)) # TODO : Move magic number to constants

            self.total_lines_cleared += lines_cleared
                        
            self.__score_lines(lines_cleared) 
            keep_clearing = lines_cleared > 0

    def __animate_line_clears(self, delta_time): # Runs every tick
        for index, (line_y, alpha, time_elapsed) in enumerate(self.fading_lines):

            time_elapsed += delta_time
            if time_elapsed >= LINE_FADE_TIME_SECONDS:
                self.fading_lines.pop(index)
                return
            
            alpha = ((LINE_FADE_TIME_SECONDS - time_elapsed) / LINE_FADE_TIME_SECONDS) * FULL_OPACITY_ALPHA
            width = GRID_PIXEL_SIZE * GRID_WIDTH
            height = GRID_PIXEL_SIZE
            transparent_layer = pygame.Surface((width, height), pygame.SRCALPHA)
            pygame.draw.rect(transparent_layer, (*RGB_WHITE, alpha), (0,0, width, height))
            transparent_layer.set_alpha(alpha)
            self.fading_lines[index] = (line_y, alpha, time_elapsed)
            start_x = self.game_x_offset * GRID_PIXEL_SIZE
            start_y = (GRID_HEIGHT - line_y + self.game_y_offset) * GRID_PIXEL_SIZE
            self.screen.blit(transparent_layer, (start_x, start_y, width, height))

    def __award_score(self, score_amount):
        if score_amount <= 0:
            return
        
        self.score += score_amount
        self.__update_scoreboard()

    def __score_lines(self, lines_cleared):
        if lines_cleared <= 0:
            return
        
        match self.gamemode:
            case Gamemode.MODERN:
                points_award = MODERN_LINES_CLEARED_POINTS_REWARD[lines_cleared] 
                self.points += points_award
                score_award = (points_award * MODERN_POINTS_TO_SCORE_MULTPLIER) * self.level_index
                if score_award > 0:
                    self.__award_score(score_award)
                if self.points >= self.next_level_goal:
                    self.__level_up()

            case Gamemode.CLASSIC:
                score_award = CLASSIC_LINES_CLEARED_SCORE_REWARD[lines_cleared] * self.level_index + CLASSIC_LEVEL_INDEX_SCORE_OFFSET
                self.__award_score(score_award)
                self.lines_cleared += lines_cleared
                if self.lines_cleared >= self.next_level_goal:
                    self.__level_up()
                    self.lines_cleared = 0

    def __level_up(self):
        self.level_index += 1
        
        match self.gamemode:
            case Gamemode.MODERN:
                self.points -= self.next_level_goal
                self.next_level_goal = self.base_goal * self.level_index
            case Gamemode.CLASSIC:
                self.next_level_goal = CLASSIC_NEXT_LEVEL_BASE_GOAL

        self.__update_scoreboard()
        self.__calc_drop_speed()

    def __game_over(self):
        self.is_playing = False

    def __draw_game_over_frame(self):
        self.screen.fill(RGB_BLACK)
        image_height = self.screen.get_height()
        image_width = GRID_WIDTH * GRID_PIXEL_SIZE
        scaled_image = pygame.transform.scale(self.game_over_image, (image_width, image_height))
        scaled_rect = scaled_image.get_rect()
        scaled_rect.center = (self.screen.get_width() / 2, self.screen.get_height() / 2) # Is the 2 a magic number here? 
        self.screen.blit(scaled_image, scaled_rect)
        pygame.display.update()

    def tick(self, delta_time, fps): # Called in main
        if not self.is_playing:
            self.__draw_game_over_frame()
            return

        match self.gamemode:
            case Gamemode.MODERN:
                if self.is_down:
                    self.down_time_elapsed += delta_time

                if self.down_time_elapsed >= MODERN_MAX_DOWN_TIME_SECONDS:
                    self.__hard_drop_tetromino()
                    self.down_time_elapsed = 0
                    self.is_down = False
            case Gamemode.CLASSIC:
                if self.is_down:
                    self.__lock_piece()

        self.drop_time_elapsed += delta_time
        if self.drop_time_elapsed >= self.drop_interval:
            self.__drop_tetromino()
            self.drop_time_elapsed = 0
    
        self.__draw_grid()
        self.__draw_ghost_piece()
        self.__animate_line_clears(delta_time)
        self.__draw_border()
        self.__draw_tetromino()
        self.__draw_next_piece_preview()

        if self.gamemode == Gamemode.CLASSIC:
            return

    def begin_play(self): # Called in main
        self.__bind_input(self)   

    def __update_scoreboard(self):
        for player in self.players:
            set_player_score_data(player.player_id, self.score, self.level_index, self.total_lines_cleared)

    ## Inputs ##

    def __bind_input(self, tetris):
        players = get_active_players_for_game(GAME_NAME)
        for i, player in enumerate(players):
            def make_input_handler(player_index=i):
                def handle_tetris_input(player_obj, payload):
                    cmd = payload.get("cmd")  # TODO : Remove magic string, replace with constant
                    match cmd:
                        case "MOVE_LEFT":  # TODO : Remove magic string, replace with constant
                            tetris.move_piece_left()
                        case "MOVE_RIGHT":
                            tetris.__move_piece_right()
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
        self.__move_tetromino(offset=(-1,0))
        self.__moved()

    def move_piece_right(self):
        self.__move_tetromino(offset=(1,0))
        self.__moved()

    def rotate_clockwise(self):
        self.__rotate_tetromino()
        self.__moved()

    def rotate_counterclockwise(self):
        self.__rotate_tetromino(clockwise=False)
        self.__moved()

    def drop_piece(self, is_pressed):
        match self.gamemode:
            case Gamemode.MODERN:
                if not is_pressed:
                    return
                
                self.__drop_tetromino()       
                self.__moved(wants_to_lock=True)
            case Gamemode.CLASSIC:
                self.is_soft_dropping = is_pressed
                self.__calc_drop_speed()
                if not is_pressed:
                    self.soft_drop_streak = 0

    def hard_drop_piece(self):
        if self.gamemode == Gamemode.CLASSIC:
            return

        self.__hard_drop_tetromino(was_player_called=True)
        self.__moved(wants_to_lock=True)