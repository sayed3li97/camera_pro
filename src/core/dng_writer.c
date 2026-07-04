/*
 * dng_writer.c — Minimal, dependency-free Linear-DNG writer with EXIF.
 *
 * Writes an uncompressed 8-bit linear-RGB DNG (a TIFF container with the DNG
 * required tags) plus an EXIF IFD carrying ISO, exposure time, and timestamps.
 * No libtiff/libexif: the TIFF structure is emitted directly. Output parses in
 * macOS ImageIO (sips/Preview), Adobe DNG-aware readers, and exiftool.
 *
 * Layout: TIFF header → IFD0 (+ external values) → EXIF IFD (+ values) → pixels.
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#include "camera_pro_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* TIFF type codes */
#define T_BYTE      1
#define T_ASCII     2
#define T_SHORT     3
#define T_LONG      4
#define T_RATIONAL  5
#define T_SRATIONAL 10

typedef struct {
    uint16_t tag;
    uint16_t type;
    uint32_t count;
    uint32_t value;   /* inline value or offset */
} ifd_entry_t;

typedef struct {
    ifd_entry_t entries[32];
    int         count;
} ifd_t;

static void ifd_add(ifd_t* ifd, uint16_t tag, uint16_t type, uint32_t count, uint32_t value) {
    ifd->entries[ifd->count].tag = tag;
    ifd->entries[ifd->count].type = type;
    ifd->entries[ifd->count].count = count;
    ifd->entries[ifd->count].value = value;
    ifd->count++;
}

static void put16(uint8_t* p, uint16_t v) { p[0] = v & 0xFF; p[1] = v >> 8; }
static void put32(uint8_t* p, uint32_t v) {
    p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; p[2] = (v >> 16) & 0xFF; p[3] = v >> 24;
}

static void write_ifd(FILE* f, const ifd_t* ifd, uint32_t next_ifd_offset) {
    uint8_t buf[12];
    put16(buf, (uint16_t)ifd->count);
    fwrite(buf, 1, 2, f);
    for (int i = 0; i < ifd->count; i++) {
        put16(buf + 0, ifd->entries[i].tag);
        put16(buf + 2, ifd->entries[i].type);
        put32(buf + 4, ifd->entries[i].count);
        put32(buf + 8, ifd->entries[i].value);
        fwrite(buf, 1, 12, f);
    }
    put32(buf, next_ifd_offset);
    fwrite(buf, 1, 4, f);
}

/* Encodes an ASCII value: returns bytes needed in the external-value area
 * (0 if it fits inline). */
static uint32_t ascii_extern_len(const char* s) {
    uint32_t n = (uint32_t)strlen(s) + 1;
    return n <= 4 ? 0 : n;
}

int32_t camera_pro_write_dng(
    const char* path,
    const uint8_t* px, int32_t width, int32_t height, int32_t stride,
    int32_t is_bgra,
    int32_t iso, int64_t exposure_ns,
    const char* make, const char* model, const char* datetime) {

    if (!path || !px || width <= 0 || height <= 0)
        return CAMERA_ERROR_INVALID_PARAMETER;
    if (stride <= 0) stride = width * 4;
    if (!make) make = "camera_pro";
    if (!model) model = "camera_pro";
    if (!datetime) datetime = "2026:01:01 00:00:00";

    const uint32_t pixel_bytes = (uint32_t)width * (uint32_t)height * 3;
    static const char software[] = "camera_pro 0.0.1";
    const uint8_t dng_version[4] = {1, 4, 0, 0};

    /* ── Compute layout ──────────────────────────────────────────────────
     * header(8) | IFD0 | ifd0 external values | EXIF IFD | exif values | pixels
     */
    const uint32_t hdr = 8;

    /* IFD0 entry count is fixed below (15 entries). */
    ifd_t ifd0; memset(&ifd0, 0, sizeof(ifd0));
    ifd_t exif; memset(&exif, 0, sizeof(exif));

    /* Sizes of external values for IFD0 */
    const uint32_t bps_len = 6;                            /* 3 SHORTs        */
    const uint32_t make_len = ascii_extern_len(make);
    const uint32_t model_len = ascii_extern_len(model);
    const uint32_t sw_len = ascii_extern_len(software);
    const uint32_t dt_len = ascii_extern_len(datetime);
    const uint32_t ucm_len = ascii_extern_len(model);      /* UniqueCameraModel */

    /* IFD0 has 20 entries (keep in sync with the adds below!). */
    const uint32_t ifd0_entries = 20;
    const uint32_t ifd0_off = hdr;
    const uint32_t ifd0_sz = 2 + ifd0_entries * 12 + 4;
    uint32_t voff = ifd0_off + ifd0_sz;                    /* external values  */

    const uint32_t bps_off = voff;   voff += bps_len;
    const uint32_t make_off = voff;  voff += make_len;
    const uint32_t model_off = voff; voff += model_len;
    const uint32_t sw_off = voff;    voff += sw_len;
    const uint32_t dt_off = voff;    voff += dt_len;
    const uint32_t ucm_off = voff;   voff += ucm_len;
    const uint32_t cm_off = voff;    voff += 9 * 8;        /* ColorMatrix1     */

    /* EXIF IFD: 3 entries (ExposureTime, ISO, DateTimeOriginal). */
    const uint32_t exif_entries = 3;
    const uint32_t exif_off = voff;
    const uint32_t exif_sz = 2 + exif_entries * 12 + 4;
    voff = exif_off + exif_sz;
    const uint32_t exptime_off = voff; voff += 8;          /* 1 RATIONAL      */
    const uint32_t dto_len = ascii_extern_len(datetime);
    const uint32_t dto_off = voff;     voff += dto_len;

    const uint32_t pixels_off = voff;

    /* ── IFD0 entries (must be ascending by tag) ───────────────────────── */
    ifd_add(&ifd0, 254, T_LONG, 1, 0);                     /* NewSubfileType  */
    ifd_add(&ifd0, 256, T_LONG, 1, (uint32_t)width);       /* ImageWidth      */
    ifd_add(&ifd0, 257, T_LONG, 1, (uint32_t)height);      /* ImageLength     */
    ifd_add(&ifd0, 258, T_SHORT, 3, bps_off);              /* BitsPerSample   */
    ifd_add(&ifd0, 259, T_SHORT, 1, 1);                    /* Compression=none*/
    ifd_add(&ifd0, 262, T_SHORT, 1, 34892);                /* Photometric=LinearRaw */
    ifd_add(&ifd0, 271, T_ASCII, (uint32_t)strlen(make) + 1,
            make_len ? make_off : 0);                      /* Make            */
    ifd_add(&ifd0, 272, T_ASCII, (uint32_t)strlen(model) + 1,
            model_len ? model_off : 0);                    /* Model           */
    ifd_add(&ifd0, 273, T_LONG, 1, pixels_off);            /* StripOffsets    */
    ifd_add(&ifd0, 274, T_SHORT, 1, 1);                    /* Orientation     */
    ifd_add(&ifd0, 277, T_SHORT, 1, 3);                    /* SamplesPerPixel */
    ifd_add(&ifd0, 278, T_LONG, 1, (uint32_t)height);      /* RowsPerStrip    */
    ifd_add(&ifd0, 279, T_LONG, 1, pixel_bytes);           /* StripByteCounts */
    ifd_add(&ifd0, 305, T_ASCII, (uint32_t)strlen(software) + 1, sw_off);
    ifd_add(&ifd0, 306, T_ASCII, (uint32_t)strlen(datetime) + 1, dt_off);
    ifd_add(&ifd0, 34665, T_LONG, 1, exif_off);            /* ExifIFD pointer */
    {
        uint32_t v = 0;
        memcpy(&v, dng_version, 4);
        ifd_add(&ifd0, 50706, T_BYTE, 4, v);               /* DNGVersion      */
    }
    ifd_add(&ifd0, 50708, T_ASCII, (uint32_t)strlen(model) + 1,
            ucm_len ? ucm_off : 0);                        /* UniqueCameraModel */
    ifd_add(&ifd0, 50721, T_SRATIONAL, 9, cm_off);         /* ColorMatrix1    */
    ifd_add(&ifd0, 50778, T_SHORT, 1, 21);                 /* CalibIlluminant1=D65 */

    if ((uint32_t)ifd0.count != ifd0_entries) return CAMERA_ERROR_UNKNOWN;

    /* Inline short ASCII values (<= 4 bytes) get packed into the value field. */
    for (int i = 0; i < ifd0.count; i++) {
        if (ifd0.entries[i].type == T_ASCII && ifd0.entries[i].count <= 4 &&
            ifd0.entries[i].value == 0) {
            const char* s = (ifd0.entries[i].tag == 271) ? make : model;
            uint32_t v = 0;
            memcpy(&v, s, ifd0.entries[i].count);
            ifd0.entries[i].value = v;
        }
    }

    /* ── EXIF entries ────────────────────────────────────────────────────── */
    ifd_add(&exif, 33434, T_RATIONAL, 1, exptime_off);     /* ExposureTime    */
    ifd_add(&exif, 34855, T_SHORT, 1,
            (uint32_t)(iso < 0 ? 0 : (iso > 65535 ? 65535 : iso)));
    ifd_add(&exif, 36867, T_ASCII, (uint32_t)strlen(datetime) + 1, dto_off);

    /* ── Emit ──────────────────────────────────────────────────────────── */
    FILE* f = fopen(path, "wb");
    if (!f) return CAMERA_ERROR_CAPTURE_FAILED;

    uint8_t head[8] = {'I', 'I', 42, 0, 0, 0, 0, 0};
    put32(head + 4, ifd0_off);
    fwrite(head, 1, 8, f);

    write_ifd(f, &ifd0, 0);

    uint8_t sbuf[8];
    put16(sbuf, 8); put16(sbuf + 2, 8); put16(sbuf + 4, 8);
    fwrite(sbuf, 1, bps_len, f);                            /* BitsPerSample  */
    if (make_len) fwrite(make, 1, make_len, f);
    if (model_len) fwrite(model, 1, model_len, f);
    fwrite(software, 1, sw_len, f);
    fwrite(datetime, 1, dt_len, f);
    if (ucm_len) fwrite(model, 1, ucm_len, f);

    /* ColorMatrix1: XYZ(D65) → linear-sRGB camera space, x10000 rationals. */
    {
        static const int32_t cm[9] = {
            32405, -15371, -4985,
            -9693,  18760,   416,
              556,  -2040, 10572,
        };
        uint8_t rb[8];
        for (int i = 0; i < 9; i++) {
            put32(rb, (uint32_t)cm[i]);
            put32(rb + 4, 10000);
            fwrite(rb, 1, 8, f);
        }
    }

    write_ifd(f, &exif, 0);

    /* ExposureTime as ns/1e9 rational. */
    put32(sbuf, (uint32_t)(exposure_ns < 0 ? 0 : (uint64_t)exposure_ns / 1000));
    put32(sbuf + 4, 1000000);                               /* microsec / 1e6 */
    fwrite(sbuf, 1, 8, f);
    fwrite(datetime, 1, dto_len, f);

    /* Pixel data: RGB, dropping alpha, honouring channel order. */
    const int ri = is_bgra ? 2 : 0;
    const int bi = is_bgra ? 0 : 2;
    uint8_t* row = (uint8_t*)malloc((size_t)width * 3);
    if (!row) { fclose(f); return CAMERA_ERROR_OUT_OF_MEMORY; }
    for (int32_t y = 0; y < height; y++) {
        const uint8_t* src = px + (size_t)y * stride;
        for (int32_t x = 0; x < width; x++) {
            row[x * 3 + 0] = src[x * 4 + ri];
            row[x * 3 + 1] = src[x * 4 + 1];
            row[x * 3 + 2] = src[x * 4 + bi];
        }
        fwrite(row, 1, (size_t)width * 3, f);
    }
    free(row);

    /* Sanity: our layout math must match what we actually wrote. */
    long pos = ftell(f);
    fclose(f);
    if (pos < 0 || (uint32_t)pos != pixels_off + pixel_bytes) {
        return CAMERA_ERROR_UNKNOWN;
    }
    return CAMERA_OK;
}
