cmake_minimum_required(VERSION 3.13)

if(NOT DEFINED PICO_SDK_PATH)
  if(DEFINED ENV{PICO_SDK_PATH})
    set(PICO_SDK_PATH $ENV{PICO_SDK_PATH})
  else()
    message(FATAL_ERROR "Set PICO_SDK_PATH to a pico-sdk checkout")
  endif()
endif()

include(${PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(joy_harness_rp2040 C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_executable(joy_harness_rp2040
  src/main.c
  src/usb_descriptors.c
)

target_include_directories(joy_harness_rp2040 PRIVATE src)
target_link_libraries(joy_harness_rp2040 PRIVATE pico_stdlib tinyusb_device tinyusb_board)

pico_enable_stdio_usb(joy_harness_rp2040 0)
pico_enable_stdio_uart(joy_harness_rp2040 0)
pico_add_extra_outputs(joy_harness_rp2040)
