const w4 = @import("wasm4.zig");
const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const swap = std.mem.swap;

const v3 = @Vector(3, f32);
const v2 = @Vector(2, f32);
// const u3 = @Vector(2, u32);
const iv3 = @Vector(3, i32);
const vers = @Vector(4, f32); // 1, j, k, l

// One world unit := 200m.
const knots = 1.943844 * 2.0; // knots / (m/s)
const craft_height = 0.008;
const rot_null = vers{1, 0, 0, 0};
const rot_half = vers{0, 0, 1, 0};
const screen_w = 160;
const screen_h = 120;
const fov_fac = 1.2;
const Depth = u8;
const depth_scale = 255;
// const size = 160;
const relative_max_depth = 30;
var max_depth: f32 = relative_max_depth;
const runway1 = grid(0, 0) + v3{0, 1, 0};

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
    .{
        .sky = 0x7cb9cb, // blueish white
        .ground1 = 0x5e7b60, // light green
        .ground2 = 0x50605b, // dark green
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
    w4.PALETTE.* = .{
        0x6cb9cb, // sky
        0x5e8360, // light green
        0x405b4b, // dark green
        0x664f4e, // brown
    };
    w4.SYSTEM_FLAGS.preserve_framebuffer = true;
    w4.SYSTEM_FLAGS.hide_gamepad_overlay = true;
}

fn adsr(a: u8, d: u8, s: u8, r: u8) u32 {
    return (@as(u32, a) << 24) + (@as(u32, d) << 16) + @as(u32, s) + (@as(u32, r) << 8);
}

const cam_start = v3{ 0, 2, 10 };

var cam_pos = cam_start;
var cam_rot = rot_half;
var angular_speed = rot_null;
var surface_speed = v3{0,0,-1};
var controls_position = v3{0,0,0}; // pitch,roll,yaw

comptime {
    const base = v3{1, 2, 3};
    const rotated = rot(base, rot_null);
    if (!(all(rotated == base)))
        @compileLog("{}", rotated);
}


var depth: [screen_w][screen_h]Depth = undefined;
var state: enum {
    begin,
    running,
    dead,
} = .begin;

var fatality: enum {
    crash,
} = .crash;

var frame: u32 = 0;
var altitude: f32 = 100;
var cam_offset: v3 = v3{0,0,0};
var ground_normal: v3 = undefined;
var steer: v3 = v3{0,0,0};
var trim: v3 = v3{0,0,0};
var throttle: f32 = 1;


export fn update() void {
    if (state == .begin) {
        std.mem.set(u8, w4.FRAMEBUFFER[0..], 0);
        w4.DRAW_COLORS.fill = 3;
        w4.DRAW_COLORS.outline = 1;
        w4.text(\\
            \\ Gamepad1 [arrows]:
            \\ throttle/yaw
            \\
            \\ Gamepad2 [ESDF]:
            \\  pitch/roll
            \\
            \\
            \\
            \\
            \\ Good luck, pilot!
            \\   [X] to start.
            , 2, 18);
        if (w4.GAMEPAD[0].button1)
            startGame();
        return;
    } else if (state == .dead) {
        std.mem.set(u8, w4.FRAMEBUFFER[0..], 255);
        w4.DRAW_COLORS.fill = 2;
        w4.DRAW_COLORS.outline = 0;
        const cause = switch (fatality) {
            .crash => "     CRASHED"
        };
        w4.text(cause, 10, 10);
        w4.DRAW_COLORS.fill = 1;
//         w4.text("\n\n\n\n\n\n\n\n     R. I. P.\n\n\n\n\n\n\n\n  [R] to restart.", 8, 8);
        w4.text(" Restart\n\n In\n\n Peace.\n\n\n\n\n\n\n   [X]", 45, 60);
        if (w4.GAMEPAD[0].button1)
            startGame();
        return;
    }
    w4.DRAW_COLORS.fill = 0;
    w4.DRAW_COLORS.outline = 3;

    const gamepad = w4.GAMEPAD[0];
    const throttle_speed = 0.03;
    if (gamepad.down)
        throttle -= throttle_speed;
    if (gamepad.up)
        throttle += throttle_speed;
    throttle = math.clamp(throttle, 0, 1);

    const drag_min = 0.02;
    const thrust = 0.04;
    const gravity = -0.1;
    _ = gravity;

    var stalling: bool = false;

    const wing_main = wingForce(from_axis(.{1, 0, 0}, 5), 0.09, 0.0003, &stalling);
    const wing_side = wingForce(from_axis(.{0, 0, 1}, 90), 0.02, 0.00005, null);

//     const torque = cross(wing_main, ;

    const acc =
        wing_main + wing_side
        + v3{0, gravity, 0}
        + rot(.{0, 0, -thrust*throttle}, cam_rot)
        + scale(surface_speed, -@minimum(30, drag_min) * len(surface_speed))
    ;

    _ = acc;
    surface_speed += scale(acc, 1/60.0);

    cam_pos += scale(surface_speed, 1.0/60.0 * 2.0/3.0);

    const paddle = w4.GAMEPAD[1];
    const turnspeed = 0.5;
//     const pitch_speed = from_axis(.{1, 0, 0}, turnspeed);
//     const roll_speed = from_axis(.{0, 0, 1}, turnspeed*1.5);
//     const yaw_speed = from_axis(.{0, 1, 0}, turnspeed*0.5);

    const turn_acc = 0.05;
    const turn_reset = 0.1;

    if (paddle.up)
        steer[1] -= turn_acc;
    if (paddle.down)
        steer[1] += turn_acc;
    if (!paddle.up and !paddle.down)
        steer[1] = moveTo(steer[1], trim[1], turn_reset);
    if (paddle.left)
        steer[2] += turn_acc;
    if (paddle.right)
        steer[2] -= turn_acc;
    if (!paddle.left and !paddle.right)
        steer[2] = moveTo(steer[2], trim[2], turn_reset);
    if (gamepad.right)
        steer[0] -= turn_acc;
    if (gamepad.left)
        steer[0] += turn_acc;
    if (!gamepad.right and !gamepad.left)
        steer[0] = moveTo(steer[0], trim[0], turn_reset);

    steer = @maximum(v3{-1,-1,-1}, @minimum(v3{1,1,1}, steer));
    cam_rot =
        mult(mult(mult(cam_rot,
            from_axis(.{0, 1, 0}, steer[0] * turnspeed*0.5)),
            from_axis(.{1, 0, 0}, steer[1] * turnspeed*1.0)),
            from_axis(.{0, 0, 1}, steer[2] * turnspeed*1.5));


    const groundheight = cam_pos[1] - gridheight(cam_pos[0], cam_pos[2]);
    const max_impact = 0.04; // 12m/s
    ground_normal = v3{
        -(gridheight(cam_pos[0]+0.05, cam_pos[1]) - gridheight(cam_pos[0]-0.05, cam_pos[1])) / 0.1,
        1,
        -(gridheight(cam_pos[0], cam_pos[1]+0.05) - gridheight(cam_pos[0], cam_pos[1]-0.05)) / 0.1,
    };
    ground_normal = scale(ground_normal, 1/len(ground_normal));

    const landed = groundheight <= craft_height;
    const braking = throttle == 0 and gamepad.down;
    if (landed) {
        const impact_speed = dot(surface_speed, ground_normal);
        if (@fabs(impact_speed) > max_impact) {
            state = .dead;
        } else {
            surface_speed -= scale(ground_normal, impact_speed);
            // 9m/s² brakes, oh well
            if (braking)
                surface_speed -= scale(surface_speed, 0.03/len(surface_speed)/60.0);
        }

        cam_pos[1] = gridheight(cam_pos[0], cam_pos[2]) + craft_height;
    }

    const near_ground = math.clamp(1 - groundheight, 0, 1);

//     const time = @intToFloat(f32, frame) / 60;
//     cam_offset = v3{0, @cos(time*60), 0} * full(near_ground * 0.002);

    const current_biome = biome(cam_pos[0], cam_pos[2]);
    w4.PALETTE[0] = current_biome.sky;
    w4.PALETTE[1] = current_biome.ground1;
    w4.PALETTE[2] = current_biome.ground2;
//     w4.PALETTE[0..3].* = .{ current_biome.sky, current_biome.ground1, current_biome.ground2 };

    std.mem.set(u8, w4.FRAMEBUFFER[0..screen_w*screen_h/4], 0);
    std.mem.set(Depth, @ptrCast(*[screen_w*screen_h]Depth, &depth), math.maxInt(Depth));


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
                quad(c, 1, 2); // Tris
//                 const col = @floatToInt(u8, @mod(u + v, 2)) + 1;
//                 quad(c, col, col); // Squares
//                 quad(c, col, 3 - col); // Stripes

                const level = 0.5;
                const water = c[0][1] < level or c[1][1] < level or c[2][1] < level or c[3][1] < level;
                if (water) {
                    quad(.{
                        v3{u, level, v},
                        v3{u+1, level, v},
                        v3{u, level, v+1},
                        v3{u+1, level, v+1},
                    }, 0, 0);
                }
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
    tooltip(v3{-1.25, 0.9, -0.75}, &TEE);



    // ======================== INSTRUMMENTS ========================

    std.mem.set(u8, w4.FRAMEBUFFER[screen_w*screen_h/4..], 255);
    w4.DRAW_COLORS.fill = 1;
//     w4.oval(6, screen_h+6, 28, 28);
//     w4.oval(120, screen_h+6, 28, 28);
//     circle(20, screen_h + 20, 14);

    // Throttle
    const throttle_x = 110;
    w4.DRAW_COLORS.outline = 2;
    w4.DRAW_COLORS.fill = 3;
    w4.rect(throttle_x, screen_h + 6, 4, 28);
    w4.DRAW_COLORS.outline = 3;
    w4.DRAW_COLORS.fill = 1;
    w4.rect(throttle_x-4, screen_h + 32 - @floatToInt(i32, throttle*28), 12, 4);


    // Altimeter
//     w4.DRAW_COLORS.fill = 2;
//     circle(140, screen_h + 20, 14);
//     w4.DRAW_COLORS.outline = 4;
//     w4.DRAW_COLORS.fill = 0;
//     w4.blit(&alti_text, 135, screen_h+25, 16, 4, w4.BLIT_1BPP);
//     w4.DRAW_COLORS.fill = 1;
//     hand(140, screen_h + 20, 12, -groundheight * 1.0);
//     w4.DRAW_COLORS.fill = 1;
//     hand(140, screen_h + 20, 8, -groundheight * 0.3);


    // Yoke
    w4.DRAW_COLORS.fill = 4;
    w4.DRAW_COLORS.outline = 2;
    const controls_size = 31;
    w4.rect(72, screen_h + 4, controls_size, controls_size);
    w4.DRAW_COLORS.fill = 0;
    w4.DRAW_COLORS.outline = 1;
    circle(72 + controls_size/2 + @floatToInt(i32, @round(controls_size * 0.9 * -steer[2] / 2)),
        screen_h + 19 + @floatToInt(i32, @round(controls_size * 0.9  * steer[1] / 2)), 2);


//     hand(140, screen_h + 20, 8, -groundheight * 0.5);

//     w4.DRAW_COLORS.fill = 0;
//     const h = math.absInt(@floatToInt(i32, rot(.{0, 1, 0}, cam_rot)[1] * 14)) catch return;
//     w4.oval(6, screen_h+20-h, 28, 2*h);

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
    num(50, heading_display_y+6, @floatToInt(u32, len(surface_speed) * 100 * knots));
    w4.blit(&knots_text, 56, heading_display_y+8, 8,4, w4.BLIT_1BPP);

    const pitch_display_y = screen_h+21;
    w4.blit(&pitch_text, 8, pitch_display_y, 16,4, w4.BLIT_1BPP);
    num(19, pitch_display_y+6, @floatToInt(u32, @fabs(@round(pitch))));
    w4.blit(&degrees_text, 24, pitch_display_y+6, 3,3, w4.BLIT_1BPP);
    if (@round(pitch) > 0)
        w4.blit(&numbers[10], 6, pitch_display_y+6, 4, 6, w4.BLIT_1BPP);

    w4.blit(&alti_text, 42, pitch_display_y, 16, 4, w4.BLIT_1BPP);
    num(50, pitch_display_y+6, @floatToInt(u32, groundheight * 1000));
    w4.blit(&feet_text, 48, pitch_display_y+8, 16,4, w4.BLIT_1BPP);


    w4.DRAW_COLORS.fill = 4;
    w4.DRAW_COLORS.outline = 0;

    var y: i32 = 8;

    var altwarn = false;
    var future: f32 = 0;
    while (future < 40) : (future += 1) {
        const nextpos = cam_pos + scale(surface_speed, future * 4 / 60);
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
    }
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
//     print("{d:.2}\n{d:.2}\n{d:.2}", .{surface_speed[0], surface_speed[1], surface_speed[2]});
//     print("{d:.2}\n{d:.2}", .{pitch_aoa, lift});


    frame += 1;
}

/// A null angle is the reasonable default orientation relative to the plane.
/// Result is actually plain acceleration.
fn wingForce(angle: vers, area: f32, drag: f32, stalling: ?*bool) v3 {
    const stall_start = 18;
    const stall_reduction = 0.05;

    const wing_angle = mult(cam_rot, angle);
    const relative_air = rot(surface_speed, conj(wing_angle));

    const a = len(v2{relative_air[1], relative_air[2]});
    const pitch_aoa = -std.math.atan2(f32, relative_air[1] / a, -relative_air[2] / a) / math.pi * 180;
//     const pitch_aoa = @as(f32, 0.0);
    const stall_amount = math.clamp((@fabs(pitch_aoa)-@as(f32, stall_start))*0.2, 0.0, 1.0);

    const lift = math.clamp(pitch_aoa * area, -5, 5) * (1 - (1-stall_reduction) * stall_amount);
    const speed_squared = dot(surface_speed, surface_speed);

    if (stalling) |dest|
        dest.* = stall_amount > 0.1;
    return rot(v3{0, lift * speed_squared, 0}, wing_angle) - scale(surface_speed, len(surface_speed) * drag);
}

fn startGame() void {
    state = .running;
    cam_pos = cam_start;
    cam_rot = rot_null;
    angular_speed = rot_null;
    surface_speed = v3{0,0,-1};
    angular_momentum = v3{0,0,0};
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
    if (all(cam_pos > p) and all(cam_pos < p + v3{w, h, d}))
        state = .dead;

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
    const width = 0.5;
    const length = 2;

    quad(.{
        origin + v3{width, 0, length},
        origin + v3{width, 0, -length},
        origin + v3{-width, 0, length},
        origin + v3{-width, 0, -length},
    }, 3, 3);
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
        .x = clamptoint((x[0] / dist + 0.5) * screen_w*fov_fac),
        .y = clamptoint((x[1] / dist + 0.5 * @as(f32, screen_h)/screen_w) * screen_w*fov_fac),
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
    const bim = biome(x, y);
    const u = x / 3;
    const v = y / 3;
    return ((@fabs(@sin(u)) + @fabs(@sin(v+0.3*u)) + 0.2*@sin(u*6.7) + 0.2*@cos(v*6.9))
        * (1 + (@cos(u/21.7) + @sin(v/22.3))*0.2 ))
        * @intToFloat(f32, bim.height_scale) / 100;
}

fn gridheight(xs: f32, ys: f32) f32 {
    if (@fabs(xs - runway1[0]) < 0.5 and @fabs(ys - runway1[2]) < 2)
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

fn cross(a: v3, b: v3) v3 {
    return .{
        a[1]*b[2] - a[2]*b[1],
        a[2]*b[0] - a[0]*b[2],
        a[0]*b[1] - a[1]*b[0],
    };
}




/// ax must be normalized
fn from_axis(comptime ax: v3, ang: f32) vers {
    const r = ang / 360 * math.pi;
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

fn norm(x: vers) vers {
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
    0b11101001, 0b11010000,
    0b10101000, 0b10010000,
    0b11101000, 0b10010000,
    0b10101100, 0b10010000,
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

