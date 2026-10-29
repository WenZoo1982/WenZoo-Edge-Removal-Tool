export async function onRequest({ request, env }) {
    // 读取现有的 PowerShell 脚本，不修改原文件
    const url = new URL(
        "/WenZoo-Edge-Removal-Tool.ps1",
        request.url
    );

    const upstream = await env.ASSETS.fetch(url);

    if (!upstream.ok) {
        return new Response("Unable to load PowerShell script.", {
            status: upstream.status,
            headers: {
                "Content-Type": "text/plain; charset=utf-8"
            }
        });
    }

    // 直接检查 UTF-8 BOM 的三个字节，避免重新解码中文
    const bytes = new Uint8Array(await upstream.arrayBuffer());

    const hasBom =
        bytes.length >= 3 &&
        bytes[0] === 0xEF &&
        bytes[1] === 0xBB &&
        bytes[2] === 0xBF;

    const body = hasBom ? bytes.slice(3) : bytes;
    const headers = new Headers(upstream.headers);

    headers.set("Content-Type", "text/plain; charset=utf-8");
    headers.set("Cache-Control", "no-store");

    // 响应正文已经改变，删除原文件对应的长度和校验信息
    headers.delete("Content-Length");
    headers.delete("Content-Encoding");
    headers.delete("ETag");
    headers.delete("Content-MD5");

    return new Response(body, {
        status: upstream.status,
        headers
    });
}