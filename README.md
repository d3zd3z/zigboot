# Zigboot

This is Zigboot 0.0.1

Zigboot is (currently) an experimental bootloader project attempting
to bring the functionality of MCUboot, but in the Zig programming
language.  This initial version supports building as a Zephyr
application.

## Notes

- The swap-hash can be done with either a prefix of a SHA256 result,
  or Murmur2 32.  The SHA256 is about 20 times slower, but we already
  need that code for the image verification.  Using Murmur adds 206
  bytes of code.
