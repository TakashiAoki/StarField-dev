#version 450
#pragma tweak_shader(version="1.0")

// ============================================================
// nearfield_v2.glsl — 近景の星間浮遊物 (point3版 / StarFieldフォーク専用)
// starfield v2と同じカメラモデル (位置/姿勢行列/画角/速度ベクトル連動)。
// 差分: 疎・大粒・ソフトディスク描画 (ボケ玉風)・弱ストリーク・
//       近距離限定フェード・わずかな漂い (時間の純関数なので状態レスのまま)
// 2026-07-02 Win Elena
//
// AE側expression配線: starfield_v7と同一 (6本: focal/cam/vel/cam_right/cam_up/cam_fwd)
// 注: point3入力はStarFieldフォーク(v0.1.2+)専用。本家TweakShaderでは読めない
// Credits:
//   - hash関数: "Hash without Sine" by David Hoskins (MIT)
//     https://www.shadertoy.com/view/4djSRW
// ============================================================

#pragma utility_block(ShaderInputs)
layout(push_constant) uniform ShaderInputs {
    float time;
    float time_delta;
    float frame_rate;
    uint frame_index;
    vec4 mouse;
    vec4 date;
    vec3 resolution;
    uint pass_index;
};

layout(location = 0) out vec4 out_color;

#pragma input(float, name=density, default=0.4, min=0.05, max=1.5)
#pragma input(float, name=size, default=0.05, min=0.005, max=0.3)
#pragma input(float, name=streak, default=0.15, min=0.0, max=1.0)
#pragma input(float, name=brightness, default=0.6, min=0.0, max=4.0)
#pragma input(float, name=drift, default=0.15, min=0.0, max=1.0)
#pragma input(float, name=range, default=14.0, min=4.0, max=24.0)
#pragma input(float, name=edge, default=0.35, min=0.05, max=0.9)
#pragma input(float, name=seed, default=0.0, min=0.0, max=100.0)
#pragma input(float, name=near_fade, default=3.0, min=0.5, max=20.0)
#pragma input(float, name=near_soft, default=1.5, min=0.1, max=10.0)
#pragma input(float, name=far_soft, default=6.0, min=0.5, max=20.0)
#pragma input(float, name=opacity, default=1.0, min=0.0, max=1.0)
// ---- 以下はカメラ配線系 (expression駆動・手では触らない) ----
#pragma input(float, name=focal, default=1.5, min=0.1, max=10.0)
#pragma input(point3, name=cam, default=[6.4, 3.6, 0.0])
#pragma input(point3, name=vel, default=[0.0, 0.0, 6.0])
#pragma input(point3, name=cam_right, default=[1.0, 0.0, 0.0])
#pragma input(point3, name=cam_up, default=[0.0, 1.0, 0.0])
#pragma input(point3, name=cam_fwd, default=[0.0, 0.0, 1.0])
#pragma input(color, name=tint, default=[0.72, 0.78, 0.88, 1.0])
layout(set = 0, binding = 1) uniform CustomInput {
    float density;
    float size;
    float streak;
    float brightness;
    float drift;
    float range;
    float edge;
    float seed;
    float near_fade;
    float near_soft;
    float far_soft;
    float opacity;
    float focal;
    vec3  cam;
    vec3  vel;
    vec3  cam_right;
    vec3  cam_up;
    vec3  cam_fwd;
    vec4  tint;
};

const int   LAYERS  = 12;
const float SPACING = 2.0;
const float DEPTH   = float(LAYERS) * SPACING;

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

float seg_dist(vec2 P, vec2 A, vec2 B) {
    vec2 g = B - A;
    vec2 h = P - A;
    float t = clamp(dot(g, h) / max(dot(g, g), 1e-8), 0.0, 1.0);
    return length(h - g * t);
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 0.5 * resolution.xy) / resolution.y;

    mat3 M = mat3(cam_right, cam_up, cam_fwd);
    mat3 Mi = transpose(M);
    vec3 dir = M * normalize(vec3(uv, focal));

    float shutter = streak / max(frame_rate, 1.0);
    vec3 cam_prev = cam - vel * shutter;

    float cell = 1.0 / density;
    vec3 col = vec3(0.0);

    if (abs(dir.z) > 0.02) {
        for (int i = 0; i < LAYERS; i++) {
            float wz_rel = mod(float(i) * SPACING - cam.z, DEPTH);
            if (wz_rel < 0.3) continue;
            float plane_z = cam.z + wz_rel;
            float pidx = floor(plane_z / SPACING + 0.5);

            float t = wz_rel / dir.z;
            if (t < 0.0) continue;
            vec2 hit = cam.xy + dir.xy * t;

            vec2 grid_ofs = hash22(vec2(pidx * 13.7 + seed, pidx * 41.3)) * cell;
            vec2 gp = hit + grid_ofs;
            vec2 base_id = floor(gp / cell);

            // 近景は粒が大きくセル境界をはみ出すため隣接3x3をチェック (四角クリッピング防止)
            for (int dy = -1; dy <= 1; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    vec2 id = base_id + vec2(float(dx), float(dy));
                    vec2 sd = id + pidx * 71.37;
                    vec2 rnd = hash22(sd);
                    float h = hash12(sd + 17.17);
                    if (h < 0.85) continue; // 大半のセルは空 (疎な浮遊物)

                    vec3 P = vec3((id + 0.15 + rnd * 0.7) * cell - grid_ofs, plane_z);
                    // 漂い: 時間の純関数のゆっくりした揺れ (状態レス維持)
                    float ph = h * 6.2831;
                    P.xy += drift * vec2(sin(time * (0.25 + h * 0.3) + ph),
                                         cos(time * (0.21 + h * 0.25) + ph * 1.7)) * 0.6;

                    vec3 q1 = Mi * (P - cam);
                    vec3 q2 = Mi * (P - cam_prev);
                    if (q1.z < 0.3 || q2.z < 0.3) continue;
                    vec2 s1 = q1.xy / q1.z * focal;
                    vec2 s2 = q2.xy / q2.z * focal;
                    float d = seg_dist(uv, s1, s2);

                    // ソフトディスク (近いほど大きい・個体差あり)
                    float R = size * (0.4 + 1.3 * h) * focal / q1.z;
                    float disc = 1.0 - smoothstep(R * (1.0 - edge), R, d);
                    // 縁に淡いハロ (ボケ玉感)
                    float halo = exp(-pow(d / (R * 1.8), 2.0)) * 0.25;

                    // 近傍フェードはカメラ空間距離q1.z基準 (Particular Near Fade相当)、遠側はrangeで消える
                    float fade = smoothstep(near_fade - near_soft, near_fade, q1.z)
                               * (1.0 - smoothstep(range - far_soft, range, wz_rel));
                    float lum = (disc * 0.85 + halo) * fade / (1.0 + q1.z * q1.z * 0.03);

                    vec3 c = mix(tint.rgb, vec3(1.0, 0.95, 0.85), fract(h * 5.0) * 0.35);
                    col += c * lum;
                }
            }
        }
    }

    col *= brightness * opacity;
    // 不透明出力 + レイヤー側を加算合成にする (微小アルファはアンプリマルチで白飛びする)
    out_color = vec4(col, 1.0);
}
