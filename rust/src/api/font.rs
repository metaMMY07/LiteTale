/// Decode chapter fonts on the bridge worker pool, never on Flutter's UI thread.
pub fn decode_chapter_font(data: Vec<u8>) -> anyhow::Result<Vec<u8>> {
    anyhow::ensure!(data.len() >= 4 && data.len() <= 16 * 1024 * 1024, "Invalid chapter font size");
    if &data[..4] == b"wOF2" {
        anyhow::ensure!(data.len() >= 48, "Truncated WOFF2 header");
        let decoded_size = u32::from_be_bytes(data[16..20].try_into()?);
        anyhow::ensure!(decoded_size > 0 && decoded_size <= 32 * 1024 * 1024, "Chapter font is too large");
        woofwoof::decompress(&data).ok_or_else(|| anyhow::anyhow!("Chapter font decoding failed"))
    } else {
        anyhow::ensure!(&data[..4] == b"\x00\x01\x00\x00" || &data[..4] == b"OTTO", "Unsupported chapter font format");
        Ok(data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_truncated_and_oversized_headers() {
        assert!(decode_chapter_font(b"wOF2".to_vec()).is_err());
        let mut header = vec![0; 48];
        header[..4].copy_from_slice(b"wOF2");
        header[16..20].copy_from_slice(&u32::MAX.to_be_bytes());
        assert!(decode_chapter_font(header).is_err());
        assert!(decode_chapter_font(b"html".to_vec()).is_err());
    }
}
