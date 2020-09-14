# An example which uses Zif::LayeredTileMap and Zif::Camera
class World < Zif::Scene
  include Zif::Traceable
  attr_accessor :map, :camera, :avatar, :last_rendered_camera

  # For init
  attr_accessor :ready, :progress, :finished_at

  def initialize
    @tracer_service_name = :tracer
    @missed_ticks = 0

    mark('#initialize: Begin')
    @map = Zif::LayeredTileMap.new('map', 64, 64, 50, 50)
    @map.new_tiled_layer(:tiles)
    @map.new_tiled_layer(:stuff, true)
    @map.new_simple_layer(:avatar)
    @map.new_simple_layer(:top_effects, false, true)
    mark('#initialize: Map + layers created')
    @map.force_refresh
    @map.layers[:tiles].should_render = false
    @map.layers[:stuff].should_render = false
    @map.layers[:avatar].should_render = true
    mark('#initialize: Map refreshed')

    @avatar = Avatar.new(
      $game.services[:sprite_registry].construct('dragon_1'),
      500,
      700,
      @map.max_width,
      @map.max_height
    )

    @map.layers[:avatar].source_sprites = [@avatar]

    @ready = false
    @progress = Hash.new(0)
    @finished_at = Hash.new((@map.logical_width * @map.logical_height) - 1)
    puts "World#initialize: Initializing #{@map.logical_width}x#{@map.logical_height}"
    puts "  =#{@finished_at[:tiles] + 1} Tiles"

    mark('#initialize: Nearly finished')
    initialize_tiles

    mark('#initialize: Tiles initialized')
  end

  # For loading bar
  def initialization_percent(kind=:tiles)
    @ready ? 1.0 : (@progress[kind] / @finished_at[kind].to_f)
  end

  # If we attempt to initialize the entire map in 1 tick, everything will freeze up until it finishes.
  # So this is a method for loading which is designed to prevent this and allow us to show a loading bar.
  # The idea is that we run this once per tick, several times until initialization is finished.
  def initialize_tiles
    return if @ready

    %i[tiles stuff].each do |kind|
      next if @progress[kind] >= @finished_at[kind]

      cur_y, cur_x = @progress[kind].divmod @map.logical_width
      # puts "World#initialize_tiles(#{kind}): #{@progress[kind]}/#{@finished_at[kind]} ="
      # puts "  #{(initialization_percent * 100).floor}%"

      start_t = Time.now

      center = [@map.logical_width.idiv(2), @map.logical_height.idiv(2)]

      cur_y.upto(@map.logical_height - 1) do |y|
        # Invert Y so sprites lower on the screen overlap higher ones
        actual_y = (@map.logical_height - 1) - y
        cur_x.upto(@map.logical_width - 1) do |x|
          @progress[kind] += 1

          cur_tile = case kind
                     when :tiles
                       $game.services[:sprite_registry].construct(:white_1).tap do |s|
                         rads = Zif.radian_angle_between_points(x, actual_y, *center)
                         hue = (rads + Math::PI).fdiv(2 * Math::PI) * 360
                         r, g, b = Zif.hsv_to_rgb(hue, 100, 100 * distance_from_center(x, actual_y))
                         s.name = "floor_#{x}_#{actual_y}"
                         s.r = r
                         s.g = b
                         s.b = g
                       end
                     when :stuff
                       # TODO: Add some stuff
                     end

          @map.layers[kind].add_positioned_sprite(x, actual_y, cur_tile) if cur_tile

          # Allow this to execute for 8ms (half a tick at 60fps).
          return if (Time.now - start_t) >= 0.008 # rubocop:disable Lint/NonLocalExitFromIterator
        end
        cur_x = 0
      end
    end
    puts 'World#initialize_tiles: Finished'
    @ready = true
  end

  def distance_from_center(x1, y1, x2=@map.logical_width.idiv(2), y2=@map.logical_height.idiv(2))
    dist = Zif.distance(x1, y1, x2, y2)
    1.0 - dist.fdiv(@map.logical_width.idiv(2))
  end

  def finish_initialization
    puts 'World#finish_initialization: Begin'
    @camera = Zif::Camera.new(
      @map.target_name,
      @map.layer_containing_sprites,
      Zif::Camera::DEFAULT_SCREEN_WIDTH,
      Zif::Camera::DEFAULT_SCREEN_HEIGHT,
      0,
      400
    )

    @map.layers[:tiles].should_render = true
    refresh_map
    @map.layers[:tiles].should_render = false

    @map.layers[:tiles].containing_sprite.on_mouse_up = lambda do |point|
      combined_click = Zif.add_positions(point, @camera.pos)
      puts "Map clicked! #{point} -> #{combined_click}"
      @avatar.start_walking(combined_click)
    end

    @map.layers[:tiles].containing_sprite.on_mouse_down = ->(point) { puts "Map clicked down! #{point}" }

    $game.services[:action_service].reset_actionables
    $game.services[:input_service].reset_clickables
    $game.services[:action_service].register_actionable(@avatar)
    $game.services[:action_service].register_actionable(@camera)
    $game.services[:input_service].register_clickable(@map.layers[:tiles].containing_sprite)

    $gtk.args.outputs.static_sprites << @camera.layers
    # $gtk.args.outputs.static_labels  << @hud_labels
    # puts "World#finish_initialization: Initialized World"
  end

  def perform_tick
    mark('#perform_tick: Begin')

    $gtk.args.outputs.background_color = [0, 0, 0, 0]
    mark('#perform_tick: Init')

    @camera.start_following(@avatar) if @avatar.walking
    mark('#perform_tick: Main sequence finished')

    refresh_map
    mark('#perform_tick: Map refreshed')

    perform_tick_debug_labels
    mark('#perform_tick: Finished')
  end

  def refresh_map
    current_camera_pos = @map.logical_pos(*@camera.pos)
    @map.layers[:stuff].should_render = current_camera_pos != @last_rendered_camera
    @map.refresh
    @last_rendered_camera = current_camera_pos
  end

  def prepare_scene
    finish_initialization if @ready && @camera.nil?

    @avatar.run_animation_sequence(:fly)
  end

  # rubocop:disable Layout/LineLength
  def perform_tick_debug_labels
    color = {r: 255, g: 255, b: 255, a: 255}
    $gtk.args.outputs.labels << { x: 8, y: 720 - 200 - 8, text: "#{$gtk.args.gtk.current_framerate}fps" }.merge(color)
    $gtk.args.outputs.labels << { x: 8, y: 720 - 200 - 128, text: "Missed Ticks: #{@missed_ticks}" }.merge(color)

    if @avatar
      $gtk.args.outputs.labels << { x: 8, y: 720 - 200 - 48, text: "Avatar: #{@avatar.xy.join('x')}" }.merge(color)
      $gtk.args.outputs.labels << { x: 8, y: 720 - 200 - 28, text: "Moving: #{$gtk.args.inputs.directional_vector}" }.merge(color) if $gtk.args.inputs.directional_vector
      $gtk.args.outputs.labels << { x: 8, y: 720 - 200 - 28, text: "Moving: #{@avatar.moving_to}" }.merge(color) unless @avatar.moving_to&.all?(&:zero?)
    end

    return unless @camera

    $gtk.args.outputs.labels << { x: 8, y: 720 - 200 - 68, text: "Camera: #{@camera.pos.join('x')} -> #{@camera.cur_w}x#{@camera.cur_h}.  Target #{@camera.target_x}x#{@camera.target_y}" }.merge(color)
  end
  # rubocop:enable Layout/LineLength
end
