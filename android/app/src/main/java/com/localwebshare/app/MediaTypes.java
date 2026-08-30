package com.localwebshare.app;

import java.util.Locale;

final class MediaTypes {
    static String extension(String name) {
        int p = name.lastIndexOf('.');
        return p >= 0 ? name.substring(p + 1).toLowerCase(Locale.ROOT) : "";
    }

    static String kind(String name) {
        switch (extension(name)) {
            case "jpg": case "jpeg": case "png": case "gif": case "webp": case "heic": case "heif": case "tif": case "tiff": case "bmp": return "image";
            case "mp3": case "m4a": case "aac": case "wav": case "aiff": case "aif": case "caf": case "flac": case "ogg": return "audio";
            case "mp4": case "m4v": case "mov": case "avi": case "mpeg": case "mpg": case "webm": case "mkv": return "video";
            case "glb": case "gltf": case "usd": case "usda": case "usdc": case "usdz": case "obj": case "stl": case "ply": case "abc": case "dae": case "fbx": case "3ds": case "3mf": case "blend": case "step": case "stp": case "iges": case "igs": return "threeD";
            case "pdf": case "txt": case "rtf": case "html": case "htm": case "json": case "xml": case "md": case "csv": return "document";
            default: return "file";
        }
    }

    static String mime(String name) {
        switch (extension(name)) {
            case "mp3": return "audio/mpeg";
            case "m4a": case "aac": return "audio/mp4";
            case "wav": return "audio/wav";
            case "flac": return "audio/flac";
            case "ogg": return "audio/ogg";
            case "mp4": case "m4v": return "video/mp4";
            case "mov": return "video/quicktime";
            case "webm": return "video/webm";
            case "glb": return "model/gltf-binary";
            case "gltf": return "model/gltf+json";
            case "usd": case "usda": case "usdc": return "model/vnd.usd";
            case "usdz": return "model/vnd.usdz+zip";
            case "obj": return "model/obj";
            case "stl": return "model/stl";
            case "jpg": case "jpeg": return "image/jpeg";
            case "png": return "image/png";
            case "gif": return "image/gif";
            case "webp": return "image/webp";
            case "pdf": return "application/pdf";
            case "txt": case "md": return "text/plain; charset=utf-8";
            case "html": case "htm": return "text/html; charset=utf-8";
            case "json": return "application/json; charset=utf-8";
            case "xml": return "application/xml; charset=utf-8";
            case "csv": return "text/csv; charset=utf-8";
            case "zip": return "application/zip";
            default: return "application/octet-stream";
        }
    }
}
