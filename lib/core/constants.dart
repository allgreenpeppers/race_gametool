/// Global constants for the grid system and track conventions.
///
/// The entire pipeline is grid-based: 1 cell = 16x16 pixels.
/// A standard road is 5 cells wide (80 px).
class GridConstants {
  GridConstants._();

  /// Pixel size of a single grid cell.
  static const double cellSize = 16.0;

  /// Standard road width expressed in grid cells.
  static const int roadWidthCells = 5;

  /// Standard road width expressed in pixels.
  static const double roadWidthPixels = roadWidthCells * cellSize;

  /// How far the island footprint expands beyond the track bounds
  /// before smoothing (Phase 2 island generation).
  static const int islandPaddingCells = 4;
}
