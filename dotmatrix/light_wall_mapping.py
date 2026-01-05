import csv


def load_light_wall_mapping(csv_file="dotmatrix/Light Wall Mapping.csv"):
    """
    Load the Light Wall mapping CSV and create a lookup table.
    The CSV has physical grid layout where each cell contains the FPP pixel index.
    
    Returns a dictionary: (row, col) -> pixel_index
    """
    mapping = {}
    
    with open(csv_file, 'r') as f:
        reader = csv.reader(f)
        for row_idx, row in enumerate(reader):
            for col_idx, cell in enumerate(row):
                if cell.strip():  # Only process non-empty cells
                    pixel_index = int(cell.strip())
                    mapping[(row_idx, col_idx)] = pixel_index
    
    return mapping


def create_fpp_buffer_from_grid(dot_colors, mapping):
    """
    Convert a 2D grid of colors to FPP's expected buffer format using the mapping.
    
    Args:
        dot_colors: 2D list [row][col] = (r, g, b)
        mapping: dict of (row, col) -> pixel_index from CSV
    
    Returns:
        bytearray of 13500 bytes with proper FPP pixel ordering
    """
    buffer = bytearray(13500)
    
    for (row, col), pixel_idx in mapping.items():
        if row < len(dot_colors) and col < len(dot_colors[0]):
            r, g, b = dot_colors[row][col]
            # Each pixel takes 3 bytes (RGB)
            buffer[pixel_idx * 3] = r
            buffer[pixel_idx * 3 + 1] = g
            buffer[pixel_idx * 3 + 2] = b
    
    return buffer
