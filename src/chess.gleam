import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element
import lustre/element/html
import lustre/element/svg
import lustre/event
import lustre_http

const white_king_symbol = "♔"

const black_king_symbol = "♚"

const white_queen_symbol = "♕"

const black_queen_symbol = "♛"

const white_rook_symbol = "♖"

const black_rook_symbol = "♜"

const white_bishop_symbol = "♗"

const black_bishop_symbol = "♝"

const white_knight_symbol = "♘"

const black_knight_symbol = "♞"

const white_pawn_symbol = "♙"

const black_pawn_symbol = "♟"

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

type ChessGame

type Side {
  White
  Black
}

type Kind {
  King
  Queen
  Rook
  Bishop
  Knight
  Pawn
}

type Piece {
  Piece(Kind, Side)
  NoPiece
}

type Notification {
  ErrorNotification(text: String)
}

type DrawKind {
  Stalemate
  FiftyMoveRule
  InsufficientMaterial
  ThreefoldRepetition
}

type Conclusion {
  Draw(DrawKind)
  Win(Side)
}

type Phase {
  Playing
  GameOver(Conclusion)
}

type Player {
  Human
  Api(url: String)
}

type GameState {
  GameState(
    phase: Phase,
    board: List(Piece),
    selection: Option(Int),
    recent_move: Option(#(Int, Int)),
    side_to_move: Side,
    white_player: Player,
    black_player: Player,
    game: ChessGame,
    notification: Option(Notification),
  )
}

type PreGameModel {
  PreGameModel(url: String)
}

type Model {
  PreGame(PreGameModel)
  Game(state: GameState)
}

type GameMessage {
  CellClicked(Int)
  ClearRecentMove
  ApiReturnedMove(Result(String, lustre_http.HttpError))
  DismissNotification
}

type PreGameMessage {
  Choose(Player, Player)
  SetUrl(String)
}

type Message {
  PreGameMessage(PreGameMessage)
  GameMessage(GameMessage)
}

fn init(_flags) -> #(Model, Effect(Message)) {
  #(PreGame(PreGameModel("http://127.0.0.1:1234")), effect.none())
}

fn update(model: Model, msg: Message) -> #(Model, Effect(Message)) {
  case model, msg {
    Game(game_state), GameMessage(game_msg) ->
      update_game_state(game_state, game_msg)
      |> pair.map_first(Game)
      |> pair.map_second(effect.map(_, GameMessage))
    PreGame(_), PreGameMessage(Choose(a, b)) ->
      state_from_game(new_game(), a, b)
      |> pair.map_first(Game)
      |> pair.map_second(effect.map(_, GameMessage))
    PreGame(_), PreGameMessage(SetUrl(url)) -> #(
      PreGame(PreGameModel(url)),
      effect.none(),
    )
    _, _ -> #(model, effect.none())
  }
}

fn update_game_state(
  game_state: GameState,
  msg: GameMessage,
) -> #(GameState, Effect(GameMessage)) {
  case player(game_state), game_state.selection, msg {
    _, _, DismissNotification -> {
      #(GameState(..game_state, notification: None), effect.none())
    }
    Api(_), _, ApiReturnedMove(Error(http_error)) -> {
      let msg = format_http_error(http_error)
      #(
        GameState(
          ..game_state,
          selection: None,
          notification: Some(ErrorNotification(msg)),
        ),
        effect.none(),
      )
    }
    Api(_), _, ApiReturnedMove(Ok(move_str)) ->
      execute_move(game_state, move_str)
    _, _, ClearRecentMove -> #(
      GameState(..game_state, recent_move: None),
      effect.none(),
    )
    Human, Some(a), CellClicked(b) if a == b -> #(
      GameState(..game_state, selection: None),
      effect.none(),
    )
    Human, None, CellClicked(b) -> {
      case piece_on_square(game_state.board, b) {
        Ok(NoPiece) | Error(Nil) -> #(game_state, effect.none())
        _ -> #(GameState(..game_state, selection: Some(b)), effect.none())
      }
    }
    Human, Some(a), CellClicked(b) -> {
      case piece_on_square(game_state.board, a) {
        Ok(NoPiece) | Error(Nil) -> #(game_state, effect.none())
        _ ->
          execute_move(game_state, square_to_string(a) <> square_to_string(b))
      }
    }
    _, _, _ -> #(game_state, effect.none())
  }
}

fn player(game_state: GameState) -> Player {
  case game_state.side_to_move {
    White -> game_state.white_player
    Black -> game_state.black_player
  }
}

fn format_http_error(http_error: lustre_http.HttpError) -> String {
  case http_error {
    lustre_http.BadUrl(_) -> "Bad URL"
    lustre_http.InternalServerError(msg) -> "Server error: 500 " <> msg
    lustre_http.JsonError(_) -> "JSON error"
    lustre_http.NetworkError -> "Network error"
    lustre_http.NotFound -> "Server error: 400 Not Found"
    lustre_http.OtherError(code, msg) ->
      "Server error: " <> int.to_string(code) <> " " <> msg
    lustre_http.Unauthorized -> "Unauthorized"
  }
}

fn execute_move(
  game_state: GameState,
  move_str: String,
) -> #(GameState, Effect(GameMessage)) {
  case move(game_state.game, move_str) {
    Error(msg) -> {
      echo msg
      #(
        GameState(
          ..game_state,
          selection: None,
          notification: Some(ErrorNotification(msg)),
        ),
        effect.none(),
      )
    }
    Ok(game) ->
      state_from_game(game, game_state.white_player, game_state.black_player)
  }
}

fn state_from_game(game: ChessGame, white_player: Player, black_player: Player) {
  let side_to_move = case side_to_move_ffi(game) {
    "w" -> White
    _ -> Black
  }
  let recent_move = case most_recent_move(game) {
    Ok(#(from, to)) -> {
      case parse_square(from), parse_square(to) {
        Ok(from), Ok(to) -> Some(#(from, to))
        _, _ -> None
      }
    }
    Error(_) -> None
  }
  #(
    GameState(
      phase: check_end_conditions(game, side_to_move),
      board: board_of(game),
      selection: None,
      recent_move:,
      side_to_move: side_to_move,
      white_player:,
      black_player:,
      game: game,
      notification: None,
    ),
    case side_to_move, white_player, black_player {
      White, Human, _ | Black, _, Human ->
        effect.from(clear_recent_move_timeout)
      White, Api(url), _ | Black, _, Api(url) ->
        effect.batch([
          api_move(game, url),
          effect.from(clear_recent_move_timeout),
        ])
    },
  )
}

fn api_move(game: ChessGame, url: String) {
  lustre_http.post(
    url <> "/move",
    json.object([
      #("fen", json.string(fen(game))),
      #("turn", {
        let side = case side_to_move_ffi(game) {
          "w" -> "white"
          _ -> "black"
        }
        json.string(side)
      }),
      #("failed_moves", json.array([], json.string)),
    ]),
    lustre_http.expect_text(ApiReturnedMove),
  )
}

pub fn parse_square(string: String) -> Result(Int, Nil) {
  string.pop_grapheme(string)
  |> result.try(fn(res) {
    let #(file_letter, rank_digit) = res
    use file <- result.try(case file_letter {
      "a" -> Ok(0)
      "b" -> Ok(1)
      "c" -> Ok(2)
      "d" -> Ok(3)
      "e" -> Ok(4)
      "f" -> Ok(5)
      "g" -> Ok(6)
      "h" -> Ok(7)
      _ -> Error(Nil)
    })
    use rank <- result.map(case rank_digit {
      "1" -> Ok(7)
      "2" -> Ok(6)
      "3" -> Ok(5)
      "4" -> Ok(4)
      "5" -> Ok(3)
      "6" -> Ok(2)
      "7" -> Ok(1)
      "8" -> Ok(0)
      _ -> Error(Nil)
    })
    rank * 8 + file
  })
}

fn clear_recent_move_timeout(dispatch) {
  set_timeout(1000, fn() { dispatch(ClearRecentMove) })
}

fn square_to_string(square: Int) -> String {
  let rank = 7 - { square / 8 }
  let file = square % 8
  case file {
    0 -> "a"
    1 -> "b"
    2 -> "c"
    3 -> "d"
    4 -> "e"
    5 -> "f"
    6 -> "g"
    _ -> "h"
  }
  <> int.to_string(rank + 1)
}

fn piece_on_square(board: List(Piece), index: Int) -> Result(Piece, Nil) {
  board
  |> list.drop(index)
  |> list.first
}

fn view(model: Model) {
  case model {
    Game(game_state) -> element.map(view_game_state(game_state), GameMessage)
    PreGame(pg_model) -> element.map(view_pre_game(pg_model), PreGameMessage)
  }
}

fn view_pre_game(model: PreGameModel) {
  html.div([], [
    html.div([attribute.id("lobby")], [
      html.div([attribute.id("mode-select")], [
        html.div([], [
          html.div([attribute.class("black")], [html.text(black_king_symbol)]),
          html.div([attribute.class("white")], [html.text(white_king_symbol)]),
        ]),
        html.div(
          [attribute.class("choose"), event.on_click(Choose(Human, Human))],
          [html.div([], [html.text("👤")]), html.div([], [html.text("👤")])],
        ),
        html.div(
          [attribute.class("choose"), event.on_click(Choose(Api(model.url), Api(model.url)))],
          [html.div([], [html.text("💻")]), html.div([], [html.text("💻")])],
        ),
        html.div(
          [
            attribute.class("choose"),
            event.on_click(Choose(Human, Api(model.url))),
          ],
          [html.div([], [html.text("💻")]), html.div([], [html.text("👤")])],
        ),
        html.div(
          [
            attribute.class("choose"),
            event.on_click(Choose(Api(model.url), Human)),
          ],
          [html.div([], [html.text("👤")]), html.div([], [html.text("💻")])],
        ),
      ]),
      html.div([attribute.id("api-url")], [
        html.label([], [html.text("💻")]),
        html.input([
          event.on_input(SetUrl),
          attribute.type_("text"),
          attribute.value(model.url),
        ]),
      ]),
    ]),
  ])
}

fn view_game_state(game_state: GameState) {
  let view_cell = fn(cell: Piece, index: Int) {
    let common_attrs = [
      attribute.class("cell"),
      event.on_click(CellClicked(index)),
    ]
    let common_attrs = case game_state.selection {
      Some(selected) if index == selected -> [
        attribute.class("selected"),
        ..common_attrs
      ]
      _ -> common_attrs
    }
    case cell {
      NoPiece -> html.div(common_attrs, [])
      Piece(kind, side) -> {
        let symbol = piece_symbol(kind, side)

        html.div([attribute.class(side_to_string(side)), ..common_attrs], [
          html.span([], [html.text(symbol)]),
        ])
      }
    }
  }
  html.div(
    [
      attribute.class(case player(game_state) {
        Human -> "human"
        Api(_) -> "computer"
      }),
    ],
    [
      html.div(
        [attribute.id("pieces")],
        list.index_map(game_state.board, view_cell),
      ),
      html.svg(
        [attribute.id("moves"), attribute.attribute("viewBox", "0 0 16 16")],
        case game_state.recent_move {
          Some(#(a, b)) -> [
            svg.polygon([
              attribute.class("move-arrow"),
              attribute.attribute("points", arrow_points(a, b)),
            ]),
          ]
          None -> []
        },
      ),
      html.div([attribute.id("fen")], [html.text(fen(game_state.game))]),
      html.div(
        [
          attribute.class(case game_state.phase {
            Playing -> "not-game-over"
            _ -> "game-over"
          }),
        ],
        [
          case game_state.phase {
            GameOver(Win(side)) ->
              html.span([attribute.class(side_to_string(side))], [
                html.text(
                  piece_symbol(Rook, side) <> "👑" <> piece_symbol(Knight, side),
                ),
              ])
            GameOver(Draw(_kind)) -> html.span([], [html.text("😴")])
            _ -> html.span([], [])
          },
        ],
      ),
      html.div([attribute.id("notifications")], case game_state.notification {
        None -> []
        Some(notification) -> [
          html.div(
            [attribute.id("notification"), event.on_click(DismissNotification)],
            [html.text(notification.text)],
          ),
        ]
      }),
    ],
  )
}

fn piece_symbol(kind: Kind, side: Side) -> String {
  case kind, side {
    Bishop, White -> white_bishop_symbol
    Bishop, Black -> black_bishop_symbol

    King, White -> white_king_symbol
    King, Black -> black_king_symbol

    Knight, White -> white_knight_symbol
    Knight, Black -> black_knight_symbol

    Pawn, White -> white_pawn_symbol
    Pawn, Black -> black_pawn_symbol

    Queen, White -> white_queen_symbol
    Queen, Black -> black_queen_symbol

    Rook, White -> white_rook_symbol
    Rook, Black -> black_rook_symbol
  }
}

fn side_to_string(side: Side) -> String {
  case side {
    White -> "white"
    Black -> "black"
  }
}

fn arrow_points(from: Int, to: Int) {
  let from_rank = int.to_float(from / 8)
  let from_file = int.to_float(from % 8)
  let to_rank = int.to_float(to / 8)
  let to_file = int.to_float(to % 8)
  let straight =
    to_file == from_file
    || to_rank == from_rank
    || float.absolute_value(to_rank -. from_rank)
    == float.absolute_value(to_file -. from_file)
  let draw = case straight {
    True -> straight_arrow
    False -> corner_arrow
  }
  draw(
    #(2.0 *. from_file +. 1.0, 2.0 *. from_rank +. 1.0),
    #(2.0 *. to_file +. 1.0, 2.0 *. to_rank +. 1.0),
    0.25,
  )
  |> list.map(fn(coords) {
    float.to_string(coords.0) <> "," <> float.to_string(coords.1)
  })
  |> string.join(" ")
}

fn straight_arrow(
  from: #(Float, Float),
  to: #(Float, Float),
  half_width: Float,
) -> List(#(Float, Float)) {
  let #(x0, y0) = from
  let #(x1, y1) = to
  let dx = x1 -. x0
  let dy = y1 -. y0
  let length = float.square_root(dx *. dx +. dy *. dy) |> result.unwrap(0.0)
  let dx = half_width *. dx /. length
  let dy = half_width *. dy /. length

  [
    // arrow base
    #(x0 -. dy, y0 +. dx),
    // arrow base
    #(x0 +. dy, y0 -. dx),
    // arrow head
    #(x1 +. dy -. dx, y1 -. dx -. dy),
    //arrow point
    #(x1, y1),
    // arrow head
    #(x1 -. dy -. dx, y1 +. dx -. dy),
  ]
}

fn corner_arrow(
  from: #(Float, Float),
  to: #(Float, Float),
  half_width: Float,
) -> List(#(Float, Float)) {
  let #(x0, y0) = from
  let #(x1, y1) = to
  let dx = x1 -. x0
  let dy = y1 -. y0
  let dx = half_width *. dx /. float.absolute_value(dx)
  let dy = half_width *. dy /. float.absolute_value(dy)
  [
    // arrow base
    #(x0 -. dy, y0),
    // arrow base
    #(x0 +. dy, y0),
    // inside corner 
    #(x0 +. dy, y1 -. dx),
    // arrow head
    #(x1 -. dx, y1 -. dx),
    // arrow point
    #(x1, y1),
    // arrow head
    #(x1 -. dx, y1 +. dx),
    // outside corner
    #(x0 -. dy, y1 +. dx),
  ]
}

fn board_of(game: ChessGame) -> List(Piece) {
  list.map(game_board_squares(game), fn(str) {
    case str {
      "bp" -> Piece(Pawn, Black)
      "bn" -> Piece(Knight, Black)
      "bb" -> Piece(Bishop, Black)
      "br" -> Piece(Rook, Black)
      "bq" -> Piece(Queen, Black)
      "bk" -> Piece(King, Black)
      "wp" -> Piece(Pawn, White)
      "wn" -> Piece(Knight, White)
      "wb" -> Piece(Bishop, White)
      "wr" -> Piece(Rook, White)
      "wq" -> Piece(Queen, White)
      "wk" -> Piece(King, White)
      _ -> NoPiece
    }
  })
}

fn opposite(side: Side) {
  case side {
    Black -> White
    White -> Black
  }
}

fn check_end_conditions(game: ChessGame, side: Side) -> Phase {
  case check_end_conditions_ffi(game) {
    "checkmate" -> GameOver(Win(opposite(side)))
    "draw-stalemate" -> GameOver(Draw(Stalemate))
    "draw-fifty-move-rule" -> GameOver(Draw(FiftyMoveRule))
    "draw-insufficient-material" -> GameOver(Draw(InsufficientMaterial))
    "draw-threefold-repetition" -> GameOver(Draw(ThreefoldRepetition))
    _ -> Playing
  }
}

@external(javascript, "./chess_ffi.mjs", "new_game")
fn new_game() -> ChessGame

@external(javascript, "./chess_ffi.mjs", "fen")
fn fen(game: ChessGame) -> String

@external(javascript, "./chess_ffi.mjs", "move")
fn move(game: ChessGame, move: String) -> Result(ChessGame, String)

@external(javascript, "./chess_ffi.mjs", "game_board_squares")
fn game_board_squares(game: ChessGame) -> List(String)

@external(javascript, "./chess_ffi.mjs", "most_recent_move")
fn most_recent_move(game: ChessGame) -> Result(#(String, String), Nil)

@external(javascript, "./chess_ffi.mjs", "set_timeout")
fn set_timeout(duration: Int, callback: fn() -> Nil) -> Nil

@external(javascript, "./chess_ffi.mjs", "check_end_conditions")
fn check_end_conditions_ffi(game: ChessGame) -> String

@external(javascript, "./chess_ffi.mjs", "side_to_move")
fn side_to_move_ffi(game: ChessGame) -> String
