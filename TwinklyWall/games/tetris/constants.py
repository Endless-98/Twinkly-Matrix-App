### GLOBAL ###
GAME_NAME = "tetris"
TETROMINO_MAX_GRID_SIZE = 4

### Game Settings ###
LINE_FADE_TIME_SECONDS = 0.5

# Classic #
CLASSIC_START_LEVEL_INDEX = 0
CLASSIC_NEXT_LEVEL_BASE_GOAL = 10
CLASSIC_FIRST_LEVEL_GOAL_FLOOR = 100
CLASSIC_FIRST_LEVEL_GOAL_FLOOR_HALF = CLASSIC_FIRST_LEVEL_GOAL_FLOOR / 2.0
CLASSIC_NES_FPS = 60.0988
CLASSIC_LINES_CLEARED_SCORE_REWARD = [0,40,100,300,1200] # Index: num lines cleared at once
CLASSIC_POINTS_PER_SOFT_DROP_STEP = 1
CLASSIC_SOFT_DROP_SPEED_DIVISOR = 2
CLASSIC_LEVEL_INDEX_SCORE_OFFSET = 1
# Modern #
MODERN_START_LEVEL_INDEX = 1
MODERN_MAX_MOVES_WHILE_DOWN = 15
MODERN_MAX_DOWN_TIME_SECONDS = 0.500
MODERN_LINES_CLEARED_POINTS_REWARD = [0,1,3,5,8] # Index: num lines cleared at once
MODERN_NEXT_LEVEL_BASE_GOAL = 5
MODERN_BASE_DROP_SPEED = 0.8
MODERN_SPEED_MULTIPLIER = 0.007
MODERN_RESET_DOWN_GAP = -2
MODERN_POINTS_TO_SCORE_MULTPLIER = 100
MODERN_RANDOM_BAG_SIZE = 7

### Grid Settings ###
GRID_WIDTH = 10
GRID_HEIGHT = 25
GRID_PIXEL_SIZE = 3
BORDER_THICKNESS = 2

### Style ###
BORDER_COLOR = (105,105,105)
FULL_OPACITY_ALPHA = (255)
RGB_BLACK = (0,0,0)
RGB_WHITE = (255,255,255)
RGBA_INVISIBLE_BLACK = (0,0,0,0)
RGBA_OFF_PIXEL_GRAY = (35,35,35,0)  
TETROMINO_GHOST_ALPHA = 65
GAME_OVER_FILENAME = 'game_over_screen.png'

### Tetromino Definition ###
TETROMINO_COLORS = [(0,0,0), (0, 230, 254),(254, 16, 60),(184, 2, 253),(24, 1, 255),(255, 222, 0),(102, 253, 0),(255, 115, 8)]

# TODO : This is terrible. Refactor to Enum with named groups
    # Use Rotation enum
    # Use Enum for Piece Group
KICK_OFFSETS = [
        ### Piece_group 0: I piece
        [
        # Counter-clockwise
            [
                # Desired rotation
                [
                    #Try number
                    (-1,0),
                    (2,0),
                    (-1,2),
                    (2,-1),
                ],
                [
                    (2,0),
                    (-1,0),
                    (2,1),
                    (-1,-2),
                ],
                [
                    (1,0),
                    (-2,0),
                    (1,-2),
                    (-2,1),
                ],
                [
                    (-2,0),
                    (1,0),
                    (-2,-1),
                    (1,2),
                ],
            ],
            # Clockwise
            [
                # Desired rotation
                [
                    #Try number
                    (-2,0),
                    (1,0),
                    (-2,-1),
                    (1,2),
                ],
                [
                    (-1,0),
                    (2,0),
                    (-1,2),
                    (2,-1),
                ],
                [
                    (2,0),
                    (-1,0),
                    (2,1),
                    (-1,-2),
                ],
                [
                    (1,0),
                    (-2,0),
                    (1,-2),
                    (-2,1),
                ],
            ],
        ],
        ### Piece_group 1
        [
            
        # Counter-clockwise
            [
                # Desired rotation
                [
                    #Try number
                    (1,0),
                    (1,1),
                    (0,-2),
                    (1,-2),
                ],
                [
                    (1,0),
                    (1,-1),
                    (0,2),
                    (1,2),
                ],
                [
                    (-1,0),
                    (-1,1),
                    (0,-2),
                    (-1,-2),
                ],
                [
                    (-1,0),
                    (-1,-1),
                    (0,2),
                    (-1,2),
                ],
            ],
            # Clockwise
            [
                # Desired rotation
                [
                    #Try number
                    (-1,0),
                    (-1,1),
                    (0,-2),
                    (-1,-2),
                ],
                [
                    (1,0),
                    (1,-1),
                    (0,2),
                    (1,2),
                ],
                [
                    (1,0),
                    (1,1),
                    (0,-2),
                    (1,-2),
                ],
                [
                    (-1,0),
                    (-1,-1),
                    (0,2),
                    (-1,2),
                ],
            ],
        ],
    ]



EMPTY = False
FILLED = True
TETROMINO_I_GRID_SHAPE = [[EMPTY,EMPTY,EMPTY,EMPTY],
                          [EMPTY,EMPTY,EMPTY,EMPTY],
                          [FILLED,FILLED,FILLED,FILLED],
                          [EMPTY,EMPTY,EMPTY,EMPTY]]

TETROMINO_J_GRID_SHAPE = [[FILLED,EMPTY,EMPTY],
                          [FILLED,FILLED,FILLED],
                          [EMPTY,EMPTY,EMPTY]]

TETROMINO_L_GRID_SHAPE = [[EMPTY,EMPTY,FILLED],
                          [FILLED,FILLED,FILLED],
                          [EMPTY,EMPTY,EMPTY]],

TETROMINO_O_GRID_SHAPE = [[EMPTY,EMPTY,EMPTY,EMPTY],
                          [EMPTY,FILLED,FILLED,EMPTY],
                          [EMPTY,FILLED,FILLED,EMPTY],
                          [EMPTY,EMPTY,EMPTY,EMPTY]]

TETROMINO_S_GRID_SHAPE = [[EMPTY,FILLED,FILLED],
                          [FILLED,FILLED,EMPTY],
                          [EMPTY,EMPTY,EMPTY]]

TETROMINO_Z_GRID_SHAPE = [[FILLED,FILLED,EMPTY],
                          [EMPTY,FILLED,FILLED],
                          [EMPTY,EMPTY,EMPTY]],

TETROMINO_T_GRID_SHAPE = [[EMPTY,FILLED,EMPTY],
                          [FILLED,FILLED,FILLED],
                          [EMPTY,EMPTY,EMPTY]]

TETROMINO_I_GRID_SIZE = 4

TETROMINO_J_GRID_SIZE = 3

TETROMINO_L_GRID_SIZE = 3

TETROMINO_O_GRID_SIZE = 4

TETROMINO_S_GRID_SIZE = 3

TETROMINO_Z_GRID_SIZE = 3

TETROMINO_T_GRID_SIZE = 3