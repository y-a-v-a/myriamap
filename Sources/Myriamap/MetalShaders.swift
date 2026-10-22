#if canImport(Metal)
/// Metal shader source for `MetalMapRenderer`, compiled when the renderer
/// is created (so the package needs no Metal build step).
///
/// Geometry stays in face-local coordinates; a per-face transform places it
/// on the flat map or on the folding globe. Points of the globe come from
/// the face planes, so night is worked out per pixel. Line widths are in
/// pixels; lines that share a colour are antialiased analytically, fills
/// and zone outlines by multisampling.
enum MetalShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct FillVertex { float2 p; uint face; uint region; };
    struct Segment { float2 a; float2 b; uint face; uint region; };
    struct FaceTransform { float4 x; float4 y; float4 z; };
    struct FacePlane { float4 origin; float4 xAxis; float4 yAxis; };
    struct RegionStyle { float4 color; float depth; float pad0, pad1, pad2; };

    struct Frame {
        float2 mapScale;      // map → pixels (top-left origin)
        float2 mapOffset;
        float2 viewportSize;  // pixels
        float depthScale;
        float folded;         // 1: shade faces turned away
        float4 sun;           // xyz: towards the sun; w: 1 to draw night
        float4 night;         // night colour, straight alpha
        float4 thresholds;    // sine of the elevation below which each night layer is dark
        float4 shade;         // colour that faces turned away are mixed with
    };

    struct FillStyle {
        float4 color;         // when not using region colours
        float depthBias;
        uint useRegion;
        float2 pad;
    };

    struct LineStyle {
        float4 lines;         // coverage: the channel of target 0 the layer goes to
        float4 highlight;     // coverage: 1 in x for target 1
        float width;          // pixels
        float depthBias;
        float2 pad;
    };

    static float3 toWorld(FaceTransform t, float2 p) {
        float4 q = float4(p, 0, 1);
        return float3(dot(t.x, q), dot(t.y, q), dot(t.z, q));
    }

    static float3 planePoint(FacePlane f, float2 p) {
        return f.origin.xyz + f.xAxis.xyz * p.x + f.yAxis.xyz * p.y;
    }

    static float2 toPixel(float3 w, constant Frame& u) { return w.xy * u.mapScale + u.mapOffset; }

    static float4 toClip(float2 px, float z, float bias, constant Frame& u) {
        return float4(px.x / u.viewportSize.x * 2 - 1, 1 - px.y / u.viewportSize.y * 2,
                      clamp(0.5 - z * u.depthScale - bias, 0.0, 1.0), 1);
    }

    static float3 shaded(float3 c, FaceTransform t, constant Frame& u) {
        return (u.folded > 0 && t.z.z < 0) ? mix(c, u.shade.rgb, 0.55) : c;
    }

    // The stacked night layers over colour c at a point of the globe, with
    // antialiased terminators.
    static float3 night(float3 c, float3 globe, constant Frame& u) {
        if (u.sun.w == 0) return c;
        float e = dot(normalize(globe), u.sun.xyz);
        float w = max(fwidth(e), 1e-7);
        float4 cover = saturate((u.thresholds - e) / w + 0.5);
        float4 clear = 1 - u.night.a * cover;
        return mix(c, u.night.rgb, 1 - clear.x * clear.y * clear.z * clear.w);
    }

    // MARK: Fills

    struct FillOut {
        float4 position [[position]];
        float3 globe;
        float4 color [[flat]];
    };

    vertex FillOut fillVertex(uint vid [[vertex_id]],
                              const device FillVertex* vertices [[buffer(0)]],
                              const device FaceTransform* transforms [[buffer(1)]],
                              const device FacePlane* planes [[buffer(2)]],
                              const device RegionStyle* regions [[buffer(3)]],
                              constant Frame& u [[buffer(4)]],
                              constant FillStyle& style [[buffer(5)]]) {
        FillVertex v = vertices[vid];
        FaceTransform t = transforms[v.face];
        float3 w = toWorld(t, v.p);
        float4 c = style.useRegion ? regions[v.region].color : style.color;
        FillOut o;
        o.position = toClip(toPixel(w, u), w.z, style.depthBias, u);
        // Where pieces of the flat map overlap, later groups lie on top.
        if (style.useRegion && u.folded == 0) o.position.z = regions[v.region].depth;
        o.globe = planePoint(planes[v.face], v.p);
        o.color = float4(shaded(c.rgb, t, u), c.a);
        return o;
    }

    // Every face in the colour of the region covering most of it, beneath
    // the fills. On the flat map the corners come placed, so faces meeting
    // at a hinge share them exactly; folding, a slight push away from the
    // viewer keeps it behind the fills in the same plane.
    vertex FillOut underlayVertex(uint vid [[vertex_id]],
                                  const device FillVertex* vertices [[buffer(0)]],
                                  const device FaceTransform* transforms [[buffer(1)]],
                                  const device FacePlane* planes [[buffer(2)]],
                                  const device RegionStyle* regions [[buffer(3)]],
                                  constant Frame& u [[buffer(4)]],
                                  const device float2* placed [[buffer(6)]]) {
        FillVertex v = vertices[vid];
        FaceTransform t = transforms[v.face];
        float3 w = u.folded == 0 ? float3(placed[vid], 0) : toWorld(t, v.p);
        FillOut o;
        o.position = toClip(toPixel(w, u), w.z, -2e-6, u);
        if (u.folded == 0) o.position.z = 0.9;
        o.globe = planePoint(planes[v.face], v.p);
        o.color = float4(shaded(regions[v.region].color.rgb, t, u), 1);
        return o;
    }

    fragment float4 fillFragment(FillOut in [[stage_in]], constant Frame& u [[buffer(0)]]) {
        float3 c = night(in.color.rgb, in.globe, u);
        return float4(c * in.color.a, in.color.a);
    }

    // MARK: Lines

    struct LineOut {
        float4 position [[position]];
        float2 local;         // along and across the segment, pixels
        float length [[flat]];
    };

    // Lines thinner than a pixel are drawn a pixel wide and fainter.
    static float halfWidth(constant LineStyle& style) { return max(style.width, 1.0) * 0.5; }

    // A segment as a quad around it, one pixel wider all round than the
    // line, so the fragment shader can shade a round-capped antialiased line.
    static LineOut expand(uint vid, Segment s, FaceTransform t, constant Frame& u, constant LineStyle& style) {
        float3 wa = toWorld(t, s.a), wb = toWorld(t, s.b);
        float2 a = toPixel(wa, u), b = toPixel(wb, u);
        float2 d = b - a;
        float len = length(d);
        float2 dir = len > 1e-6 ? d / len : float2(1, 0);
        float2 normal = float2(-dir.y, dir.x);
        float e = halfWidth(style) + 1;
        float along = (vid & 1) ? len + e : -e;
        float across = (vid & 2) ? e : -e;
        float f = len > 1e-6 ? saturate(along / len) : 0;
        LineOut o;
        o.position = toClip(a + dir * along + normal * across, mix(wa.z, wb.z, f), style.depthBias, u);
        o.local = float2(along, across);
        o.length = len;
        return o;
    }

    static float coverage(LineOut in, constant LineStyle& style) {
        float t = clamp(in.local.x, 0.0, in.length);
        float distance = length(float2(in.local.x - t, in.local.y));
        return saturate(halfWidth(style) + 0.5 - distance) * min(style.width, 1.0);
    }

    // Zone outlines, opaque and multisampled, so the GPU skips whatever
    // the fills cover. Night is worked out per vertex.
    struct SealOut {
        float4 position [[position]];
        float4 color;
    };

    static float3 nightAt(float3 c, float3 globe, constant Frame& u) {
        if (u.sun.w == 0) return c;
        float4 dark = step(dot(normalize(globe), u.sun.xyz), u.thresholds);
        float4 clear = 1 - u.night.a * dark;
        return mix(c, u.night.rgb, 1 - clear.x * clear.y * clear.z * clear.w);
    }

    vertex SealOut sealVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device Segment* segments [[buffer(0)]],
                              const device FaceTransform* transforms [[buffer(1)]],
                              const device FacePlane* planes [[buffer(2)]],
                              const device RegionStyle* regions [[buffer(3)]],
                              constant Frame& u [[buffer(4)]],
                              constant LineStyle& style [[buffer(5)]]) {
        Segment s = segments[iid];
        FaceTransform t = transforms[s.face];
        float3 wa = toWorld(t, s.a), wb = toWorld(t, s.b);
        float2 a = toPixel(wa, u), b = toPixel(wb, u);
        float2 d = b - a;
        float len = length(d);
        float2 dir = len > 1e-6 ? d / len : float2(1, 0);
        float2 normal = float2(-dir.y, dir.x);
        float hw = style.width * 0.5;
        // Square caps close the joins.
        float along = (vid & 1) ? len + hw : -hw;
        float across = (vid & 2) ? hw : -hw;
        float f = len > 1e-6 ? saturate(along / len) : 0;
        float3 globe = planePoint(planes[s.face], mix(s.a, s.b, f));
        SealOut o;
        o.position = toClip(a + dir * along + normal * across, mix(wa.z, wb.z, f), style.depthBias, u);
        o.color = float4(nightAt(shaded(regions[s.region].color.rgb, t, u), globe, u), 1);
        return o;
    }

    fragment float4 sealFragment(SealOut in [[stage_in]]) { return in.color; }

    // Lines that share a colour are accumulated as coverage first (blended
    // with max), so overlapping segments and joins don't darken.
    vertex LineOut coverageVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                  const device Segment* segments [[buffer(0)]],
                                  const device FaceTransform* transforms [[buffer(1)]],
                                  constant Frame& u [[buffer(4)]],
                                  constant LineStyle& style [[buffer(5)]]) {
        Segment s = segments[iid];
        return expand(vid, s, transforms[s.face], u, style);
    }

    struct CoverageOut {
        float4 lines [[color(0)]];
        float highlight [[color(1)]];
    };

    fragment CoverageOut coverageFragment(LineOut in [[stage_in]], constant LineStyle& style [[buffer(0)]]) {
        float a = coverage(in, style);
        return { style.lines * a, style.highlight.x * a };
    }

    // MARK: Compositing line coverage

    struct ScreenOut { float4 position [[position]]; };

    vertex ScreenOut screenVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        return { float4(p * 2 - 1, 0, 1) };
    }

    struct LineColors { float4 colors[5]; };

    fragment float4 compositeFragment(ScreenOut in [[stage_in]],
                                      texture2d<float, access::read> lines [[texture(0)]],
                                      texture2d<float, access::read> highlight [[texture(1)]],
                                      constant LineColors& palette [[buffer(0)]]) {
        uint2 p = uint2(in.position.xy);
        float4 l = lines.read(p);
        float cover[5] = { l.r, l.g, l.b, l.a, highlight.read(p).r };
        float3 c = 0;
        float a = 0;
        for (int i = 0; i < 5; i++) {
            float k = palette.colors[i].a * cover[i];
            c = palette.colors[i].rgb * k + c * (1 - k);
            a = k + a * (1 - k);
        }
        if (a <= 0) discard_fragment();
        return float4(c, a);
    }

    // MARK: Labels

    struct LabelQuad {
        float2 origin;        // pixels, top left
        float2 size;          // pixels
        float4 color;
    };

    struct LabelOut {
        float4 position [[position]];
        float2 uv;
        float4 color [[flat]];
    };

    vertex LabelOut labelVertex(uint vid [[vertex_id]], constant LabelQuad& q [[buffer(0)]],
                                constant Frame& u [[buffer(1)]]) {
        float2 corner = float2(vid & 1, (vid >> 1) & 1);
        float2 p = q.origin + corner * q.size;
        LabelOut o;
        o.position = float4(p.x / u.viewportSize.x * 2 - 1, 1 - p.y / u.viewportSize.y * 2, 0, 1);
        o.uv = corner;
        o.color = q.color;
        return o;
    }

    fragment float4 labelFragment(LabelOut in [[stage_in]], texture2d<float> text [[texture(0)]],
                                  sampler smooth [[sampler(0)]]) {
        float a = text.sample(smooth, in.uv).r * in.color.a;
        return float4(in.color.rgb * a, a);
    }
    """
}
#endif
