const w4 = @import("wasm4.zig");
const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const swap = std.mem.swap;

const v3 = @Vector(3, f32);
const v2 = @Vector(2, f32);
// const u3 = @Vector(2, u32);
const iv3 = @Vector(3, i32);
const iv2 = @Vector(2, i32);
const vers = @Vector(4, f32); // 1, j, k, l

// One world unit := 200m.
const knots = 1.943844 * 2.0; // knots / (m/s)
const craft_height = 0.01;
const rot_null = vers{1, 0, 0, 0};
const rot_half = vers{0, 0, 1, 0};
const rot_quart = norm(vers{1, 0, 1, 0});
const screen_w = 160;
const screen_h = 120;
const fov_fac = 1.0;
const Depth = u8;
const depth_scale = 255;
// const size = 160;
const relative_max_depth = 30;
var max_depth: f32 = relative_max_depth;

const runway_width = 0.5;
const runway_length = 3;
const runway1 = grid(-9, -9) + v3{0, 0.4, 0};

const Biome = packed struct {
    const Bytes = [@sizeOf(Biome)]u8;
    sky: u32,
    ground1: u32,
    ground2: u32,
    height_scale: u8,

    fn interpolate(corners: [4]Biome, u: u8, v: u8) Biome {
        const bytes = .{
            @bitCast(Bytes, corners[0]),
            @bitCast(Bytes, corners[1]),
            @bitCast(Bytes, corners[2]),
            @bitCast(Bytes, corners[3]),
        };

        var res: Bytes = undefined;
        for (res) |*r, i| {
            const upper =  @as(u32, bytes[1][i]) * u + @as(u32, bytes[0][i]) * (255 - @as(u32, u));
            const lower =  @as(u32, bytes[3][i]) * u + @as(u32, bytes[2][i]) * (255 - @as(u32, u));
            r.* = @intCast(u8, (lower * @as(u32, v) + upper * (255 - @as(u32, v))) / (255 * 255));
        }
        return @bitCast(Biome, res);
    }
};

const biomes = [_]Biome{
//     .{
//         .sky = 0x7cb9cb, // blueish white
//         .ground1 = 0x5e7b60, // light green
//         .ground2 = 0x50605b, // dark green
//         .height_scale = 102,
//     },
    .{
        .sky = 0x0cb9cb, // blueish white
        .ground1 = 0x208010, // light green
        .ground2 = 0x104808, // dark green
        .height_scale = 102,
    },
//     .{
//         .sky = 0x6c90ff, // blue
//         .ground1 = 0xebdea9, // light green
//         .ground2 = 0xcec292, // yellowish gray
//         .height_scale = 10,
//     },
};

export fn start() void {
    w4.SYSTEM_FLAGS.preserve_framebuffer = true;
    w4.SYSTEM_FLAGS.hide_gamepad_overlay = true;
}

fn adsr(a: u8, d: u8, s: u8, r: u8) u32 {
    return (@as(u32, a) << 24) + (@as(u32, d) << 16) + @as(u32, s) + (@as(u32, r) << 8);
}

const cam_start = v3{ -9, 2, 12 };
var cam_pos = cam_start;
const cam_default = from_axis(.{0, 1, 0}, 0);

// camera->world; conj(cam_rot): world->camera
var cam_rot = rot_half;
var ground_speed = v3{0,0,-1};
var controls_position = v3{0,0,0}; // pitch,roll,yaw
var angular_momentum = v3{0,0,0};
const moment_of_inertia = scale(v3{1,1,1}, 0.2);//2,3,1?
var height_rel_to_ground: bool = false;
var prev_gamepad: w4.Input = std.mem.zeroInit(w4.Input, .{});


var depth: [screen_w][screen_h]Depth = undefined;
const State = enum {
    begin,
    run_with_missiles,
};
var gamestate = State.begin;

var fatality: enum {
    alive,
    crash,
    exploded,
} = .alive;

var frame: u32 = 0;
var cam_offset: v3 = v3{0,0,0};
var ground_normal: v3 = undefined;
var steer: v3 = v3{0,0,0};
var trim: v3 = v3{0,0,0};
var throttle: f32 = 1;
var landed = false;
var missile_active = true;


var missile: Entity = undefined;
var selected_mission: u8 = 0;



export fn update() void {
    const gamepad = w4.GAMEPAD[0];
    const yoke = w4.GAMEPAD[1];
    frame += 1;

    if (gamestate == .begin) {
        w4.PALETTE.* = .{
            0x000000,
            0xffffff,
            0x20cc20,
            0x552200, // brown
        };
        w4.DRAW_COLORS.outline = 0;
        w4.DRAW_COLORS.fill = 3;
        const Mission = struct { name: []const u8, state: State };
        std.mem.set(u8, w4.FRAMEBUFFER[0..], 0);
        const missions = [_]Mission{
            .{ .name = "Escape the missile", .state = .run_with_missiles },
            .{ .name = "Escape the missile", .state = .run_with_missiles },
        };
        if (gamepad.down and !prev_gamepad.down and selected_mission + 1 < missions.len)
            selected_mission += 1;
        if (gamepad.up and !prev_gamepad.up and selected_mission > 0)
            selected_mission -= 1;

        const start_height = 20;
        for (missions) |m, i| {
            if (i == selected_mission) {
                const marker = if (frame % 40 < 20) "-" else ">";
                w4.text(marker, 2, @intCast(i32, 10 * i + start_height));
            }
            w4.text(m.name, 10, @intCast(i32, 10 * i + start_height));
        }


//         w4.text(, 8, 18);
        w4.DRAW_COLORS.fill = 2;
        w4.text("Good luck, pilot.", 14, 140);
        if (gamepad.button1) {
            gamestate = missions[selected_mission].state;
            startGame();
        }
        prev_gamepad = gamepad;
        return;
    } else if (fatality != .alive) {
        std.mem.set(u8, w4.FRAMEBUFFER[0..], 255);
        w4.DRAW_COLORS.fill = 2;
        w4.DRAW_COLORS.outline = 0;
        const cause = switch (fatality) {
            .crash =>     "     CRASHED",
            .exploded => "     EXPLODED",
            else => unreachable,
        };
        w4.text(cause, 10, 10);
        w4.DRAW_COLORS.fill = 1;
//         w4.text("\n\n\n\n\n\n\n\n     R. I. P.\n\n\n\n\n\n\n\n  [R] to restart.", 8, 8);
//         w4.text(" Restart\n\n In\n\n Peace.\n\n\n\n\n\n\n   [X]", 45, 60);
        w4.text(" Restart\n\n In\n\n Peace.\n\n\n\n  [X]", 45, 60);
        w4.DRAW_COLORS.fill = 2;
        w4.text("[C] Menu", 92, 150);
        if (gamepad.button1)
            startGame()
        else if (gamepad.button2)
            gamestate = .begin;

        prev_gamepad = gamepad;
        return;
    }



    const throttle_speed = 0.03;
    if (gamepad.down)
        throttle -= throttle_speed;
    if (gamepad.up)
        throttle += throttle_speed;
    throttle = math.clamp(throttle, 0, 1);

    const turn_acc = 0.2;
    const trim_speed = 0.002;
    const turn_reset = 0.3;

    if (gamepad.button2) {
        if (yoke.up)
            trim[1] -= trim_speed;
        if (yoke.down)
            trim[1] += trim_speed;
        steer[1] = moveTo(steer[1], trim[1], turn_reset);
        if (yoke.left)
            trim[2] += trim_speed;
        if (yoke.right)
            trim[2] -= trim_speed;
        steer[2] = moveTo(steer[2], trim[2], turn_reset);
        if (gamepad.right)
            trim[0] -= trim_speed;
        if (gamepad.left)
            trim[0] += trim_speed;


        if (gamepad.button1)
            trim = .{0,0,0};
        steer[0] = moveTo(steer[0], trim[0], turn_reset);
    } else {
        if (yoke.up)
            steer[1] -= turn_acc;
        if (yoke.down)
            steer[1] += turn_acc;
        if (!yoke.up and !yoke.down)
            steer[1] = moveTo(steer[1], trim[1], turn_reset);
        if (yoke.left)
            steer[2] += turn_acc;
        if (yoke.right)
            steer[2] -= turn_acc;
        if (!yoke.left and !yoke.right)
            steer[2] = moveTo(steer[2], trim[2], turn_reset);
        if (gamepad.right)
            steer[0] -= turn_acc;
        if (gamepad.left)
            steer[0] += turn_acc;
        if (!gamepad.right and !gamepad.left)
            steer[0] = moveTo(steer[0], trim[0], turn_reset);


        if (gamepad.button1 and !prev_gamepad.button1) {
            height_rel_to_ground = !height_rel_to_ground;
        }
    }
    const braking = throttle == 0 and gamepad.down;

    steer = @maximum(v3{-1,-1,-1}, @minimum(v3{1,1,1}, steer));


    const drag_min = 0.02;
    const thrust = 0.035;
    const gravity = -0.1;
    _ = gravity;

    var stalling: bool = false;
    const control_area = 0.6;
    const steer_angle = 0.5;
    const base_aoa: f32 = if (landed) 0 else 0.02;
    const wing_drag: f32 = if (braking) 0.5 else 0.05;
    const control_drag = 0.05;

    const wing_main_right = wingForce(.{-0.1, 1, base_aoa}, .{ 5,0,0}, 3.5, wing_drag, &stalling);
    const wing_main_left = wingForce(.{0.1, 1, base_aoa},  .{-5,0,0}, 3.5, control_drag, &stalling);
    const aileron_right = wingForce(.{0, 1, base_aoa + steer[2] * steer_angle}, .{4,0,0}, control_area, control_drag, &stalling);
    const aileron_left = wingForce(.{0, 1, base_aoa + -steer[2] * steer_angle}, .{-4,0,0}, control_area, control_drag, &stalling);
    const tail_vertical = wingForce(.{1, 0, 0}, .{0,0,10}, 2, control_drag, &stalling);
    const rudder = wingForce(.{1, 0, steer[0] * steer_angle}, .{0,0,10}, control_area, control_drag, &stalling);
    const tail_horizontal = wingForce(.{0, 1, 0.7*base_aoa}, .{0,0,10}, control_area, control_drag, &stalling);
    const elevator = wingForce(.{0, 1, 1.5*base_aoa - steer[1] * steer_angle}, .{0,0,10}, control_area, control_drag, &stalling);

    const acc =
        wing_main_right.f + wing_main_left.f + tail_vertical.f + tail_horizontal.f
        + elevator.f + aileron_left.f + aileron_right.f + rudder.f
        + v3{0, gravity, 0}
        + rot(.{0, 0, -thrust*throttle}, cam_rot)
        + scale(ground_speed, -@minimum(30, drag_min) * len(ground_speed))
    ;
    _ = acc;
    ground_speed += scale(acc, 1/60.0);
    cam_pos += scale(ground_speed, 1.0/60.0 * 2.0/3.0);

    const torque = wing_main_right.trq + wing_main_left.trq + tail_vertical.trq + tail_horizontal.trq
                + elevator.trq + aileron_left.trq + aileron_right.trq + rudder.trq;
    angular_momentum += scale(torque, 1.0/60.0);



    const altitude = cam_pos[1];
    const groundheight = altitude - gridheight(cam_pos[0], cam_pos[2]);
    const max_impact = 0.05; // 12m/s
    ground_normal = v3{
        -(gridheight(cam_pos[0]+0.05, cam_pos[1]) - gridheight(cam_pos[0]-0.05, cam_pos[1])),
        1,
        -(gridheight(cam_pos[0], cam_pos[1]+0.05) - gridheight(cam_pos[0], cam_pos[1]-0.05)),
    };
    ground_normal = scale(ground_normal, 1/len(ground_normal));
    const impact_speed = dot(ground_speed, ground_normal);
    const near_ground = math.clamp((1 - groundheight) * len(ground_speed), 0, 1);

    landed = groundheight <= craft_height;


    if (landed) {
        if (@fabs(impact_speed) > max_impact) {
            fatality = .crash;
        } else {
            ground_speed -= scale(ground_normal, impact_speed);
            // 9m/s² brakes, oh well
            if (braking)
                ground_speed -= scale(ground_speed, 0.03/len(ground_speed)/60.0);
        }

        cam_pos[1] = gridheight(cam_pos[0], cam_pos[2]) + craft_height;
        angular_momentum = scale(angular_momentum, 0.95) + scale(cross(rot(.{0,1,0}, mult(cam_rot, from_axis(.{1,0,0}, 1))), .{0,1,0}), 0.0002);
    }

    const omega = angularSpeed();
    cam_rot = versnorm(mult(from_omega(omega), cam_rot));


    const current_biome = biome(cam_pos[0], cam_pos[2]);
    w4.PALETTE[0] = current_biome.sky;
    w4.PALETTE[1] = current_biome.ground1;
    w4.PALETTE[2] = current_biome.ground2;

    std.mem.set(u8, w4.FRAMEBUFFER[0..screen_w*screen_h/4], 0);
    std.mem.set(Depth, @ptrCast(*[screen_w*screen_h]Depth, &depth), math.maxInt(Depth));



    const missile_speed = 2.0;
    const missile_forward = rot(.{0,0,1}, missile.heading);
    const missile_turnspeed = 0.04;
    const missile_delta = cam_pos - missile.pos;
    if (missile_active) {
        missile.heading = mult(from_omega(scale(-cross(norm(missile_delta), missile_forward), missile_turnspeed)), missile.heading);
        missile.pos += scale(missile_forward, missile_speed / 60.0);

        if (len(missile_delta) < 0.05) {
            fatality = .exploded;
        }
    }

    if (missile.pos[1] < gridheight(missile.pos[0], missile.pos[2]))
        missile_active = false;


    // ==================== DRAWING ====================

    // SIZE Do a groundheight->integer first.
//     const h = @floor(@log2(@maximum(1, groundheight)));
//     const groundscale = @exp2(h);
//     max_depth = relative_max_depth * groundscale;
    const groundscale = 1;

    if (true) {
        const dims = max_depth;
        var x: f32 = -dims;
        while (x < dims) : (x += 1) {
            var z: f32 = -dims;
            while (z < dims) : (z += 1) {
                const u =  (@floor(cam_pos[0] / groundscale) + x) * groundscale;
                const v =  (@floor(cam_pos[2] / groundscale) + z) * groundscale;
                const c = [4]v3{
                    grid(u, v),
                    grid(u+groundscale, v),
                    grid(u, v+groundscale),
                    grid(u+groundscale, v+groundscale),
                };
                const col = @as(u8, @boolToInt(@mod(u+v, 2) < 1));
                quad(c, 1+col, 1+col); // Tris
//                 const col = @floatToInt(u8, @mod(u + v, 2)) + 1;
//                 quad(c, col, col); // Squares
//                 quad(c, col, 3 - col); // Stripes

//                 const level = 0.5;
//                 const water = c[0][1] < level or c[1][1] < level or c[2][1] < level or c[3][1] < level;
//                 if (water) {
//                     quad(.{
//                         v3{u, level, v},
//                         v3{u+1, level, v},
//                         v3{u, level, v+1},
//                         v3{u+1, level, v+1},
//                     }, 0, 0);
//                 }
            }
        }
    }
    w4.DRAW_COLORS.fill = 1;
    paintRunway(runway1);
    cube(.{-1.5, gridheight(-1.5,-1)-1, -1}, 1.5, 0.5, 0.5, 3);
    cube(.{0.5, gridheight(0.5,-2)-1, -2}, 2, 0.2, 0.2, 3);


    w4.DRAW_COLORS.fill = 4;
    w4.DRAW_COLORS.outline = 1;
//     tooltip(v3{-0.5, 2, -9.5}, 1337);
//     tooltip(v3{-1.25, 0.9, -0.75}, &TEE);

    const missile_r = 0.03;
    missile.paint(.{0,0,0.2}, .{missile_r,0,0}, .{-missile_r,0,0}, 3);
    missile.paint(.{0,0,0.2}, .{0,missile_r,0}, .{0,-missile_r,0}, 3);
    missile.paint(.{missile_r,0,0}, .{0,missile_r,0}, .{0,-missile_r,0}, 3);
    missile.paint(.{-missile_r,0,0}, .{0,missile_r,0}, .{0,-missile_r,0}, 3);




    // ======================== INSTRUMENTS ========================

    std.mem.set(u8, w4.FRAMEBUFFER[screen_w*screen_h/4..], 255);
    w4.DRAW_COLORS.fill = 1;

    // THROTTLE
    const throttle_x = 110;
    w4.DRAW_COLORS.outline = 2;
    w4.DRAW_COLORS.fill = 3;
    w4.rect(throttle_x, screen_h + 6, 4, 28);
    w4.DRAW_COLORS.outline = 3;
    w4.DRAW_COLORS.fill = 1;
    w4.rect(throttle_x-4, screen_h + 32 - @floatToInt(i32, throttle*28), 12, 4);


    // YOKE
    w4.DRAW_COLORS.fill = 4;
    w4.DRAW_COLORS.outline = 2;
    const controls_size = 31;
    w4.rect(72, screen_h + 4, controls_size, controls_size);
    w4.DRAW_COLORS.fill = 2;
    w4.vline(72 + controls_size/2, screen_h + 4, controls_size);
    w4.hline(72, screen_h + 19, controls_size);
    w4.DRAW_COLORS.fill = 4;
    w4.DRAW_COLORS.outline = 2;
    if (gamepad.button2)
        w4.blit(&trim_text, 80, screen_h + 30, 16, 4, w4.BLIT_1BPP);

    w4.DRAW_COLORS.fill = 0;
    w4.DRAW_COLORS.outline = 1;
    circle(72 + controls_size/2 + @floatToInt(i32, @round(controls_size * 0.9 * -curt(steer[2]) / 2)),
        screen_h + 19 + @floatToInt(i32, @round(controls_size * 0.9  * curt(steer[1]) / 2)), 2);

    w4.DRAW_COLORS.fill = 1;
    w4.vline(72 + controls_size/2 + @floatToInt(i32, @round(controls_size * 0.9 * -steer[0] / 2)),
        screen_h + 20, 3);


    // INDICATORS
    w4.DRAW_COLORS.fill = 0;
    w4.DRAW_COLORS.outline = 1;
    const forward = rot(.{0, 0, 1}, cam_rot);
    const len2 = @sqrt(forward[0]*forward[0] + forward[2]*forward[2]);
    const r = v2{forward[0] / len2, forward[2] / len2};
    const heading = math.atan2(f32, r[0], r[1]);
    const pitch = 90 - math.acos(forward[1]) / math.pi * 180;
    _ = heading;
    const heading_display_y = screen_h+6;
    w4.blit(&head_text, 9, heading_display_y, 16,4, w4.BLIT_1BPP);
    num(19, heading_display_y+6, @floatToInt(u32, @mod(heading / math.pi * 180 + 180, 360)));
    w4.blit(&degrees_text, 24, heading_display_y+6, 3,3, w4.BLIT_1BPP);

    w4.blit(&speed_text, 38, heading_display_y, 16,4, w4.BLIT_1BPP);
    num(50, heading_display_y+6, @floatToInt(u32, len(ground_speed) * 100 * knots));
    w4.blit(&knots_text, 56, heading_display_y+8, 8,4, w4.BLIT_1BPP);

    const pitch_display_y = screen_h+21;
    w4.blit(&pitch_text, 8, pitch_display_y, 16,4, w4.BLIT_1BPP);
    num(19, pitch_display_y+6, @floatToInt(u32, @fabs(@round(pitch))));
    w4.blit(&degrees_text, 24, pitch_display_y+6, 3,3, w4.BLIT_1BPP);
    if (@round(pitch) > 0)
        w4.blit(&numbers[10], 6, pitch_display_y+6, 4, 6, w4.BLIT_1BPP);


    w4.blit(if (height_rel_to_ground) &ground_text else &alti_text, 42, pitch_display_y, 16, 4, w4.BLIT_1BPP);
    num(50, pitch_display_y+6, @floatToInt(u32, (if (height_rel_to_ground) groundheight else altitude + 2) * 1000));
    w4.blit(&feet_text, 48, pitch_display_y+8, 16,4, w4.BLIT_1BPP);



    // RADAR
    w4.DRAW_COLORS.fill = 3;
    w4.DRAW_COLORS.outline = 2;
    circle(radar_x, radar_y, radar_radius);
    w4.pixel(radar_x, radar_y, 1);
    radar(.{runway1[0], runway1[2]}, heading, 3);
    radar(.{runway1[0], runway1[2]+1}, heading, 3);
    radar(.{runway1[0], runway1[2]-1}, heading, 3);
    if (missile_active)
        radar(.{missile.pos[0], missile.pos[2]}, heading, @as(u8, @boolToInt(frame % 4 < 2)) * 3);


    // ARTIFICIAL HORIZON
    w4.DRAW_COLORS.fill = 2;

    const up_in_cam = rot(.{0,1,0}, conj(cam_rot));

    const screen_up_vec = v2{up_in_cam[0], up_in_cam[1]};
    const screen_up = scale2(screen_up_vec, 1/len(screen_up_vec));
    const screen_right = v2{screen_up[1], -screen_up[0]};
    const center = v2{screen_w / 2, screen_h / 2};

    var x: f32 = -90;
    while (x < 90) : (x += 10) {
        const l = math.clamp(10 - @fabs(x + pitch + 10), 0, 2) * 4;
        if (l > 0) {
            const d = scale2(screen_up, (x + pitch) *3);
            const right = center + d + scale2(screen_right, l);
            const left = center + d - scale2(screen_right, l);
            w4.line(@floatToInt(i32, right[0]), @floatToInt(i32, screen_h-right[1]),
                    @floatToInt(i32, left[0]), @floatToInt(i32, screen_h-left[1]));
        }
    }


    // SOUND
    w4.DRAW_COLORS.fill = 4;
    w4.DRAW_COLORS.outline = 0;
    var y: i32 = 8;

    var altwarn = false;
    var future: f32 = 0;
    while (future < 40) : (future += 1) {
        const nextpos = cam_pos + scale(ground_speed, future * 4 / 60);
        const nextheight = nextpos[1] - gridheight(nextpos[0], nextpos[2]);
        if (nextheight < 0.011)
            altwarn = true;
    }


    if (frame % 2 == 0) {
//         w4.tone(130, 12, 3 + @floatToInt(u32, speedsound * 6), w4.TONE_NOISE);
    }
    if (frame % 2 == 0) {
        w4.tone(75 + @floatToInt(u32, near_ground), 1, 5 + @floatToInt(u32, near_ground * 10), w4.TONE_PULSE2);
    }

    if (frame % 10 == 0) {
//         w4.tone(50, 70, 3, w4.TONE_PULSE1);
        w4.tone(50, 12, @floatToInt(u32, throttle * 100), w4.TONE_TRIANGLE);

        const missile_max_volume_dist = 0.3;
        const missile_volume = math.clamp(missile_max_volume_dist / dot(missile_delta, missile_delta), 0, 1);
        if (missile_active) {
//             w4.tone(100, 12, @floatToInt(u32, 50.0 * missile_volume), w4.TONE_NOISE);
            const direction = rot(missile_delta, conj(cam_rot));
            var mode = w4.TONE_NOISE | w4.TONE_MODE3;
            const main_component = len(v2{direction[1], direction[2]});
            if (direction[0] > main_component)
                mode |= w4.TONE_PAN_RIGHT;
            if (direction[0] < -main_component)
                mode |= w4.TONE_PAN_LEFT;
            w4.tone(90, 10, @floatToInt(u32, 50.0 * missile_volume), mode);
        }
    }


    // WARNINGS
    if (!landed) {
        if (altwarn)
            newline("ALTITUDE", &y);
        if (stalling)
            newline("STALL", &y);
    } else if (braking) {
        w4.DRAW_COLORS.fill = 2;
        newline("BRAKING", &y);
    }


    w4.DRAW_COLORS.fill = 0;
    w4.DRAW_COLORS.outline = 1;
    w4.rect(0,0, 160, screen_h);
//     w4.PALETTE[3] += 0x070503;
    w4.DRAW_COLORS.fill = 1;
    w4.DRAW_COLORS.outline = 3;






    // =========== DEBUG ============

//     const c = rot(.{0,0,-1}, cam_rot);
    const print_vals = [_]f32{
        cam_pos[0],
        cam_pos[2],
        impact_speed,
    };


    for (print_vals) |v, i| {
        const print_y = 2 + 8 * @intCast(i32, i) + 1;
        w4.DRAW_COLORS.outline = 0;
        w4.rect(2, print_y-1, 34, 8);
        w4.DRAW_COLORS.outline = 3;
        num(30, print_y, @floatToInt(u32, @fabs(v * 100)));
        w4.pixel(24, @intCast(u32, print_y + 5), 2);
        w4.pixel(24, @intCast(u32, print_y + 6), 2);
        if (v < 0) {
            w4.blit(&numbers[10], 2, print_y, 4, 6, w4.BLIT_1BPP);
        }
    }

    prev_gamepad = gamepad;
}

const radar_x = 138;
const radar_y = screen_h + 20;
const radar_radius = 18;
fn radar(point: v2, angle: f32, col: u8) void {
    const p = v2{
        point[0] - cam_pos[0],
        point[1] - cam_pos[2],
    };
    const x = @round( @cos(angle) * p[0] - @sin(angle) * p[1] );
    const y = @round( @sin(angle) * p[0] + @cos(angle) * p[1] );
    if (len(v2{x,y}) < radar_radius)
        w4.pixel(@intCast(u32, radar_x + @floatToInt(i32, x)), @intCast(u32, radar_y + @floatToInt(i32, y)), col);
}


const Entity = struct {
    pos: v3,
    heading: vers,

    fn paint(self: Entity, as: v3, bs: v3, cs: v3, col: u8) void {
        tri(
            rot(as, self.heading) + self.pos,
            rot(bs, self.heading) + self.pos,
            rot(cs, self.heading) + self.pos,
        col);
    }
};

/// Result is actually plain acceleration.
fn wingForce(normal: v3, pos: v3, area: f32, drag: f32, stalling: *bool) struct { f: v3, trq: v3 } {
    _ = drag;
    _ = area;
    _ = stalling;
    const wing_pos = rot(scale(pos, 1.0 / 300.0), cam_rot);
    const surface = rot(scale(normal, area / len(normal)), cam_rot);

    const rotational_wind = cross(angularSpeed(), wing_pos);
    const total_wind = ground_speed - rotational_wind;
    const attack = dot(-total_wind, surface);
//     const aoa = attack /
//     const additional

    const force = scale(surface, attack * len(total_wind))
            + scale(total_wind, -attack * attack / len(total_wind) * drag * area);// - scale(relative_air, len(relative_air) * drag)
    const torque = cross(wing_pos, force);

    return .{ .f = force, .trq = torque };
}

/// Result is actually plain acceleration.
fn artificialForce(angle: vers, pos: v3, plane_force: v3) struct { f: v3, trq: v3, relair: v3 } {
    const area = 1;
    const stall_start = 22;
    const stall_reduction = 0.05;

    const wing_angle = mult(angle, cam_rot);
    const relative_air = -rot(ground_speed, conj(wing_angle));// - cross(angularSpeedInCam(), scale(pos, 1.0 / 300.0));

    const a = len(v2{relative_air[1], relative_air[2]});
    const pitch_aoa = std.math.atan2(f32, relative_air[1]/a, relative_air[2]/a) / math.pi * 180;

    const stall_amount = math.clamp((@fabs(pitch_aoa)-@as(f32, stall_start))*0.2, 0.0, 1.0);

    const lift = math.clamp(pitch_aoa * area, -5, 5) * (1 - (1-stall_reduction) * stall_amount);
    _ = lift;
    const force = rot(plane_force, wing_angle);// - scale(relative_air, len(relative_air) * drag)
    const plane_torque = cross(scale(pos, 1.0 / 300.0), plane_force);
    return .{ .f = force, .trq = rot(plane_torque, conj(wing_angle)), .relair = relative_air };
}



fn startGame() void {
    fatality = .alive;
    cam_pos = cam_start;
    cam_rot = cam_default;
    ground_speed = comptime rot(v3{0,0,-1}, cam_default);
    angular_momentum = v3{0,0,0};
    missile = Entity{.pos = .{0,5,0}, .heading = comptime from_axis(.{0, 1, 0}, 90)};
    throttle = 1;
    steer = v3{0,0,0};
    trim = v3{0,0,0};
}



fn newline(text: []const u8, y: *i32) void {
    if (frame % 5 < 4)
        w4.text(text, 8, y.*);
    y.* += 8;
}

inline fn circle(x: i32, y: i32, r: i32) void {
    w4.oval(x-r, y-r, 2*r, 2*r);
}

fn num(x_begin: i32, y: i32, i: u32) void {
    var x = x_begin;
    if (i == 0) {
        w4.blit(&numbers[0], x, y, 4, 6, w4.BLIT_1BPP);
        return;
    }
    var n = i;
    while (n > 0) : (n /= 10) {
        w4.blit(&numbers[n % 10], x, y, 4, 6, w4.BLIT_1BPP);
        x -= 5;
    }
}

fn tooltip(p: v3, label: [*]const u8) void {
    var camspace = rot(p - cam_pos, conj(cam_rot));
    camspace[2] *= -1;
    camspace[1] *= -1;
    if (camspace[2] < clip_near)
        return;
    if (camspace[2] / max_depth * 7 > @intToFloat(f32, frame % 4 + 3))
        return;

    const x = project(camspace);
    if (x.x >= 0 and x.y-2 >= 0 and x.x <= screen_w and x.y <= screen_h)
        w4.pixel(@intCast(u32, x.x), @intCast(u32, x.y-2), 0);

//     num(x.x, x.y, label);
    w4.blit(label, x.x-8, x.y, 16, 4, w4.BLIT_1BPP);
}

const TEE = [8]u8 {
    0b01110111, 0b01110000,
    0b00100110, 0b01100000,
    0b00100100, 0b01000000,
    0b00100111, 0b01110000,
};

fn hand(x: i32, y: i32, r: i32, a: f32) void {
    w4.line(x, y,
        x - @floatToInt(i32, @intToFloat(f32, r)*@sin(a*math.tau)),
        y - @floatToInt(i32, @intToFloat(f32, r)*@cos(a*math.tau))
    );
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var txt: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&txt, fmt, args) catch unreachable;
    w4.text(msg, 2, 12);
}

fn cube(p: v3, h: f32, w: f32, d: f32, col: u8) void {
    _ = col;
    const c1 = 2;
    const c2 = 3;
    if (all(cam_pos > p) and all(cam_pos < p + v3{w, h, d})) {
        fatality = .crash;
    }

    rect(p + v3{w, 0, 0}, .{0, h, 0}, .{-w,0, 0}, c1, c2);
    rect(p + v3{0, 0, d}, .{0, h, 0}, .{w, 0, 0}, c1, c2);
    rect(p,               .{0, h, 0}, .{0, 0, d}, c1, c2);
    rect(p + v3{w, 0, d}, .{0, h, 0}, .{0, 0,-d}, c1, c2);
    rect(p + v3{0, h, 0}, .{0, 0, d}, .{w, 0, 0}, c1, c2);
}
fn rect(p: v3, x: v3, y: v3, col1: u8, col2: u8) void {
    quad(.{
        p,
        p + x,
        p + y,
        p + x + y,
    }, col1, col2);
}

fn paintRunway(origin: v3) void {
    const width = runway_width;
    const length = runway_length;

    quad(.{
        origin + v3{width, 0, length},
        origin + v3{width, 0, -length},
        origin + v3{-width, 0, length},
        origin + v3{-width, 0, -length},
    }, 3, 3);

    const stripe_width = 0.02;
    const stripe_length = 0.08;
    const stripe_height = 0.005;
    var x: f32 = -length*0.9;
    while (x <= length*0.9) : (x += 0.5) {
        quad(.{
            origin + v3{stripe_width, stripe_height, stripe_length + x},
            origin + v3{stripe_width, stripe_height, -stripe_length + x},
            origin + v3{-stripe_width, stripe_height, stripe_length + x},
            origin + v3{-stripe_width, stripe_height, -stripe_length + x},
        }, 0, 0);
    }
}


fn quad(c: [4]v3, col1: u8, col2: u8) void {
    tri(c[0], c[1], c[2], col1);
    tri(c[1], c[2], c[3], col2);
}

const clip_near = 0.01;
/// Transformation and clipping
fn tri(as: v3, bs: v3, cs: v3, col: u8) void {
    var a = rot(as - cam_pos, conj(cam_rot));
    var b = rot(bs - cam_pos, conj(cam_rot));
    var c = rot(cs - cam_pos, conj(cam_rot));
    a[1] *= -1;
    a[2] *= -1;
    b[1] *= -1;
    b[2] *= -1;
    c[1] *= -1;
    c[2] *= -1;

    if (a[2] < b[2])
        std.mem.swap(v3, &a, &b);
    if (b[2] < c[2])
        std.mem.swap(v3, &b, &c);
    if (a[2] < b[2])
        std.mem.swap(v3, &a, &b);
    // Now we have a >= b >= c.

    if (a[2] < clip_near) {
        return;
    } else if (b[2] < clip_near) {
        const u = clipTo(b, a);
        const v = clipTo(c, a);
        paintTri(u, v, a, col);
    } else if (c[2] < clip_near) {
        const u = clipTo(c, a);
        const v = clipTo(c, b);
        paintTri(u, v, a, col);
        paintTri(v, a, b, col);
    } else {
        paintTri(a, b, c, col);
    }
}

fn clipTo(behind: v3, front: v3) v3 {
    const d = front - behind;
    return behind + scale(d, (clip_near - behind[2]) / d[2]);
}


const oof = math.maxInt(i32);

/// Draw a transformed and clipped tri.
fn paintTri(as: v3, bs: v3, cs: v3, col: u8) void {
    var a = project(as);
    var b = project(bs);
    var c = project(cs);

    const avg_depth = @divTrunc(as[2] + bs[2] + cs[2], 3);
    if (avg_depth > depth_scale)
        return;

    if (a.x > b.x)
        swap(Projection, &a, &b);
    if (b.x > c.x)
        swap(Projection, &b, &c);
    if (a.x > b.x)
        swap(Projection, &a, &b);
    // Now we have a <= b <= c.

    if (c.x < 0 or a.x > screen_w)
        return;
    if ((a.y < 0 and b.y < 0 and c.y < 0)
        or (a.y > screen_h and b.y > screen_h and c.y > screen_h))
        return;
    if (a.x == oof or a.y == oof or b.x == oof or b.y == oof or c.x == oof or c.y == oof)
        return;

    const xd1 = b.x - a.x + 1;
    const yd1 = b.y - a.y;
    const xd2 = c.x - a.x + 1;
    const yd2 = c.y - a.y;

    const begin = clampx(a.x);
    const mid = clampx(b.x);
    var x = begin;
    while (x <= mid) : (x += 1) {
        var ybegin = a.y + @divFloor(yd1 * (@intCast(i32, x) - a.x), xd1);
        var dbegin = ilerp(a.x, a.z, b.x, b.z, x);
        var yend = a.y + @divFloor(yd2 * (@intCast(i32, x) - a.x), xd2);
        var dend = ilerp(a.x, a.z, c.x, c.z, x);
        if (ybegin > yend) {
            swap(i32, &ybegin, &yend);
            swap(f32, &dbegin, &dend);
        }
        var y = clampy(ybegin);
        while (y <= clampy(yend)) : (y += 1) {
            put(x, y, 1/ilerp(ybegin, dbegin, yend, dend, y), col);
        }
    }

    const xd3 = c.x - b.x + 1;
    const yd3 = c.y - b.y;
    const end = clampx(c.x);
    while (x <= end) : (x += 1) {
        var ybegin = a.y + @divFloor(yd2 * (@intCast(i32, x) - a.x), xd2);
        var dbegin = ilerp(a.x, a.z, c.x, c.z, x);
        var yend = b.y + @divFloor(yd3 * (@intCast(i32, x) - b.x), xd3);
        var dend = ilerp(b.x, b.z, c.x, c.z, x);
        if (ybegin > yend) {
            swap(i32, &ybegin, &yend);
            swap(f32, &dbegin, &dend);
        }
        var y = clampy(ybegin);
        while (y <= clampy(yend)) : (y += 1) {
            put(x, y, 1/ilerp(ybegin, dbegin, yend, dend, y), col);
        }
    }
}

const dither2 = [_][2]u8{
    .{ 0, 2, },
    .{ 3, 1, },
};

const dither3 = [_][3]u8{
    .{ 0, 7, 5 },
    .{ 2, 6, 1 },
    .{ 4, 3, 8 },
};

const dither4 = [_][4]u8{
    .{ 0,  8,  2, 10},
    .{12,  4, 14,  6},
    .{ 3, 11,  1,  9},
    .{15,  7, 13,  5},
};
fn put(x: u32, y: u32, dpth: f32, col: u8) void {
//     assert(d > 0 and d <= 255);
    const dr = dpth / max_depth;
    if (dr < 0 or dr > 1)
        return;
    const d = @floatToInt(Depth, @sqrt(dr)*depth_scale);
    const dither = dither2;
    const dithersize = dither[0..].len;
    const ditheroff = 3;

    if (depth[x][y] >= d) {
        const dith = dither[x%dithersize][y%dithersize];
        const c = if (dr * depth_scale * (@intToFloat(f32, dithersize*dithersize)+ditheroff)/depth_scale < @intToFloat(f32, dith + ditheroff))
            col else 0;
        w4.pixel(x, y, c);
        depth[x][y] = d;
    }
}

fn angularSpeed() v3 {
    return rot(angularSpeedInCam(), conj(cam_rot));
}
fn angularSpeedInCam() v3 {
    return rot(angular_momentum, cam_rot) / moment_of_inertia;
}


fn clampx(x: i32) u32 {
    if (x < 0) {
//         w4.pixel(100, 2, 3);
        return 0;
    }
    if (x >= screen_w) {
//         w4.pixel(100, 2, 3);
        return screen_w - 1;
    }
    return @intCast(u32, x);
}
fn clampy(x: i32) u32 {
    if (x < 0) {
//         w4.pixel(100, 2, 3);
        return 0;
    }
    if (x >= screen_h) {
//         w4.pixel(100, 2, 3);
        return screen_h - 1;
    }
    return @intCast(u32, x);
}

fn ilerp(a: i32, a_val: f32, b: i32, b_val: f32, t: u32) f32 {
    if (a == b)
        return (a_val + b_val) / 2;
    const fac = @intToFloat(f32, (@intCast(i32, t) - a)) / @intToFloat(f32, b - a);
    return (1-fac) * a_val + fac * b_val;
}


fn clamptoint(x: f32) i32 {
    return if (x < oof-1 and x > -oof+1) @floatToInt(i32, @floor(x)) else oof;
}

const Projection = struct {
    x: i32,
    y: i32,
    z: f32,
};

fn project(x: v3) Projection {
    const dist = x[2];
    return .{
        .x = clamptoint((x[0] / dist*fov_fac + 0.5) * screen_w),
        .y = clamptoint((x[1] / dist*fov_fac + 0.5 * @as(f32, screen_h)/screen_w) * screen_w),
        .z = 1 / x[2],
    };
}


fn grid(x: f32, y: f32) v3 {
    return .{x, terrainHeight(x, y), y};
}


const biome_size = 20;
fn biomeCorner(x: i32, y: i32) Biome {
    return biomes[@intCast(u32, @mod(x+y, biomes.len))];
}

fn biome(x: f32, y: f32) Biome {
    const u = x / biome_size;
    const v = y / biome_size;
    const ui = @floatToInt(i32, @floor(u));
    const vi = @floatToInt(i32, @floor(v));

    return Biome.interpolate(.{
        biomeCorner(ui, vi),
        biomeCorner(ui+1, vi),
        biomeCorner(ui, vi+1),
        biomeCorner(ui+1, vi+1),
    }, @floatToInt(u8, @mod(u, 1) * 255), @floatToInt(u8, @mod(v, 1) * 255));
}


fn terrainHeight(x: f32, y: f32) f32 {
//     const bim = biome(x, y);
    const u = x + 105;
    const v = y + 160;
    return perlin(.{u, v}, 10) * 5 -@fabs(perlin(.{u, v + 100}, 5) * 5) + perlin(.{u, v + 500}, 3) * 3;
}

fn perlin(v: v2, sc: f32) f32 {
    const cell = v2{@mod(v[0] / sc, 1), @mod(v[1] / sc, 1)};
    const lower_x = @floatToInt(i32, @floor(v[0] / sc));
    const lower_y = @floatToInt(i32, @floor(v[1] / sc));

    const corners_x = [4]f32{
        cell[0] * hash(lower_x, lower_y),
        (cell[0]-1) * hash(lower_x+1, lower_y),
        cell[0] * hash(lower_x, lower_y+1),
        (cell[0]-1) * hash(lower_x+1, lower_y+1),
    };
    const corners_y = [4]f32{
        cell[1] * hash(lower_x + 300, lower_y),
        cell[1] * hash(lower_x+1  + 300, lower_y),
        (cell[1]-1) * hash(lower_x + 300, lower_y+1),
        (cell[1]-1) * hash(lower_x+1 + 300, lower_y+1),
    };
    return lerp(corners_x, cell) + lerp(corners_y, cell);
}

fn lerp(data: [4]f32, p: v2) f32 {
    return (1-p[1]) * ((1-p[0]) * data[0] + p[0] * data[1])
             + p[1] * ((1-p[0]) * data[2] + p[0] * data[3]);
}

fn hash(x: i32, y: i32) f32 {
//     const u = @byteSwap(u32, @bitCast(u32, x)) *% 482216717;
//     const v = @byteSwap(u32, @bitCast(u32, y)) *% 644439217;

//     const d = @truncate(u16, (u >> 3) ^ (v << 11) ^ (u >> 7) ^ (v << 13));
    const a = [2]i32{x,y};
    const d = @truncate(u16, std.hash.Wyhash.hash(1337, &@bitCast([8]u8, a)));
    const c = (@intToFloat(f32, d) / 65536 - 0.5) * 2;
    return c * c * c;
}



fn gridheight(xs: f32, ys: f32) f32 {
    if (@fabs(xs - runway1[0]) < runway_width and @fabs(ys - runway1[2]) < runway_length)
        return runway1[1];

    const x = @floor(xs);
    const y = @floor(ys);
    const u = @mod(xs, 1);
    const v = @mod(ys, 1);
    return (1-u) * ((1-v) * terrainHeight(x, y) + v * terrainHeight(x, y+1)) + u * ((1-v) * terrainHeight(x+1, y) + v * terrainHeight(x+1, y+1));
}






// MATH

fn moveTo(x: f32, dest: f32, speed: f32) f32 {
    const d = @fabs(dest - x);
    const vel = @minimum(d, @sqrt(d) * speed);
    return x + math.copysign(f32, vel, dest - x);
}

fn full(p: f32) v3 {
    return .{p, p, p};
}

fn len(x: anytype) f32 {
    return @sqrt(dot(x, x));
}

fn v2iv(x: v3) iv3 {
    return .{ @floatToInt(i32, x[0]), @floatToInt(i32, x[1]), @floatToInt(i32, x[2]) };
}

inline fn dot(a: anytype, b: anytype) f32 {
    return @reduce(.Add, a*b);
}
inline fn scale(x: v3, y: f32) v3 {
    return x * @splat(3, y);
}
inline fn scale2(x: v2, y: f32) v2 {
    return x * @splat(2, y);
}

fn cross(a: v3, b: v3) v3 {
    return .{
        a[1]*b[2] - a[2]*b[1],
        a[2]*b[0] - a[0]*b[2],
        a[0]*b[1] - a[1]*b[0],
    };
}




/// ax must be normalized
fn from_axis(ax: v3, ang: f32) vers {
    const r = ang / 360 * math.pi;
    return .{ @cos(r), ax[0] * @sin(r), ax[1] * @sin(r), ax[2] * @sin(r) };
}

/// ax must be normalized
fn from_omega(om: v3) vers {
    if (len(om) == 0)
        return rot_null;
    const r = len(om);
    const ax = scale(om, 1/r);
    return .{ @cos(r), ax[0] * @sin(r), ax[1] * @sin(r), ax[2] * @sin(r) };
}

fn mult(a: vers, b: vers) vers {
    return .{
        a[0]*b[0] - a[1]*b[1] - a[2]*b[2] - a[3]*b[3],
        a[0]*b[1] + a[1]*b[0] + a[2]*b[3] - a[3]*b[2],
        a[0]*b[2] - a[1]*b[3] + a[2]*b[0] + a[3]*b[1],
        a[0]*b[3] + a[1]*b[2] - a[2]*b[1] + a[3]*b[0],
    };
}

fn toEuler(x: vers) v3 {
    return .{
        math.atan2(f32, 2.0 * (x[2] * x[3] + x[0] * x[1]), x[0] * x[0] - x[1] * x[1] - x[2] * x[2] + x[3] * x[3]),
        math.asin(-2.0 * (x[1] * x[3] - x[0] * x[2])),
        math.atan2(f32, 2.0 * (x[1] * x[2] + x[0] * x[3]), x[0] * x[0] + x[1] * x[1] - x[2] * x[2] - x[3] * x[3]),
    };
}

fn norm(x: v3) v3 {
    return x / @splat(3, @sqrt(dot(x,x)));
}

fn versnorm(x: vers) vers {
    return x / @splat(4, @sqrt(dot(x,x)));
}

fn axes(v: vers) v3 {
    return .{v[1], v[2], v[3]};
}

fn rot(v: v3, r: vers) v3 {
    return axes(mult(mult(r, vers{0, v[0], v[1], v[2]}), conj(r)));
}

fn conj(v: vers) vers {
    return .{ v[0], -v[1], -v[2], -v[3] };
}

fn all(v: anytype) bool {
    return @reduce(.And, v);
}

fn any(v: anytype) bool {
    return @reduce(.Or, v);
}

fn curt(v: f32) f32 {
    return math.copysign(f32, @sqrt(@fabs(v)), v);
}

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace) noreturn {
    _ = trace;
    w4.trace(msg);
    if (trace) |trc| {
        var buf: [32]u8 = undefined;
//         var stream = std.io.fixedBufferStream(&buf);
        for (trc.instruction_addresses) |idx| {
            const m = std.fmt.bufPrint(&buf, "{}", .{idx}) catch continue;
            w4.trace(m);
        }
//         std.debug.writeStackTrace(trc, stream, std.debug.getSelfDebugInfo());
//         w4.trace(stream.getWritten());
    }
    unreachable;
}


//
// "Yazz?"
// "Jy- Jazzz."
//


const trim_text = [8]u8{
    0b11101110, 0b10100010,
    0b01001010, 0b10110110,
    0b01001100, 0b10101010,
    0b01001010, 0b10100010,
};
const head_text = [8]u8{
    0b10101110, 0b11101000,
    0b11101100, 0b10101100,
    0b10101000, 0b11101100,
    0b10101110, 0b10101000,
};
const pitch_text = [8]u8{
    0b11010111, 0b00101010,
    0b11010010, 0b01001110,
    0b10010010, 0b01001010,
    0b10010010, 0b00101010,
};
const feet_text = [8]u8{
    0b00000000, 0b11101110,
    0b00000000, 0b11000100,
    0b00000000, 0b10000100,
    0b00000000, 0b10000100,
};
const alti_text = [8]u8{
    0b11101000, 0b11100000,
    0b10101000, 0b01000000,
    0b11101000, 0b01000000,
    0b10101110, 0b01000000,
};
const ground_text = [8]u8{
    0b10101110, 0b11100000,
    0b11101000, 0b01000000,
    0b10101010, 0b01000000,
    0b10101110, 0b01000000,
};
const speed_text = [8]u8{
    0b11011011, 0b10111010,
    0b10011011, 0b00110011,
    0b01010010, 0b00100011,
    0b11010011, 0b10111010,
};
// const knots_text = [4]u8{
//     0b10101110,
//     0b11000100,
//     0b10100100,
//     0b10100100,
// };
const knots_text = [4]u8{
    0b10101001,
    0b11001101,
    0b10101011,
    0b10101001,
};
const degrees_text = [2]u8{
    0b01010101, 0,
};


const smallnumbers = [_][5]u8{
    .{
        0b010,
        0b101,
        0b101,
        0b101,
        0b010,
    },
    .{
        0b010,
        0b010,
        0b010,
        0b010,
        0b010,
    },
    .{
        0b110,
        0b001,
        0b010,
        0b100,
        0b111,
    },
    .{
        0b111,
        0b001,
        0b011,
        0b001,
        0b111,
    },
    .{
        0b010,
        0b100,
        0b111,
        0b010,
        0b010,
    },
    .{
        0b111,
        0b100,
        0b111,
        0b001,
        0b111,
    },
    .{
        0b110,
        0b100,
        0b111,
        0b101,
        0b111,
    },
    .{
        0b111,
        0b001,
        0b010,
        0b010,
        0b010,
    },
    .{
        0b111,
        0b101,
        0b111,
        0b101,
        0b111,
    },
    .{
        0b111,
        0b101,
        0b111,
        0b001,
        0b111,
    },
    .{
        0b111,
        0b101,
        0b111,
        0b101,
        0b111,
    },
};

const numbers = [_][3]u8{
    .{
        0b01101001,
        0b10011001,
        0b10010110,
    },
    .{
        0b00100110,
        0b00100010,
        0b00100010,
    },
    .{
        0b01101001,
        0b00100100,
        0b10001111,
    },
    .{
        0b01101001,
        0b00100001,
        0b10010110,
    },
    .{
        0b00100100,
        0b10101111,
        0b00100010,
    },
    .{
        0b11111000,
        0b11100001,
        0b10010110,
    },
    .{
        0b01101000,
        0b11101001,
        0b10010110,
    },
    .{
        0b11110001,
        0b00100100,
        0b01000100,
    },
    .{
        0b01101001,
        0b01101001,
        0b10010110,
    },
    .{
        0b01101001,
        0b10010111,
        0b00010110,
    },
    .{
        0b00000000,
        0b01110000,
        0b00000000,
    },
    .{
        0b00000000,
        0b01110000,
        0b00000000,
    },
};
//     .{
//         0b11000011,
//         0b10000001,
//         0b00100100,
//         0b00100100,
//         0b00000000,
//         0b00100100,
//         0b10011001,
//         0b11000011,
//     },

