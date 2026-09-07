cmake_minimum_required(VERSION 3.16)
project(pryon_afe_runtime LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
add_compile_options(-Wall -Wextra -Werror)

include(CTest)
include(GNUInstallDirs)

add_executable(afe src/afe.c)
target_include_directories(afe PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(afe PRIVATE ${CMAKE_DL_LIBS})

add_executable(pryon src/pryon.c)
target_include_directories(pryon PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(pryon PRIVATE ${CMAKE_DL_LIBS})

install(TARGETS afe pryon RUNTIME DESTINATION bin)

if(BUILD_TESTING)
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  add_library(asp_mock SHARED mocks/libasp_mock.c)
  set_target_properties(asp_mock PROPERTIES OUTPUT_NAME "asp-mock" PREFIX "lib")
  target_include_directories(asp_mock PRIVATE ${CMAKE_SOURCE_DIR}/src)

  add_library(pryon_mock SHARED mocks/libpryon_mock.c)
  set_target_properties(pryon_mock PROPERTIES OUTPUT_NAME "pryon-mock" PREFIX "lib")
  target_include_directories(pryon_mock PRIVATE ${CMAKE_SOURCE_DIR}/src)
  target_link_libraries(pryon_mock PRIVATE m)
  install(TARGETS asp_mock pryon_mock LIBRARY DESTINATION lib)

  add_executable(pipeline-c examples/c/pipeline.c)
  add_test(NAME afe_mock COMMAND ${CMAKE_COMMAND} -E env
    ASP_LIB=$<TARGET_FILE:asp_mock>
    ${CMAKE_SOURCE_DIR}/tests/afe_stream_test.sh $<TARGET_FILE:afe>)
  add_test(NAME pryon_mock COMMAND ${CMAKE_COMMAND} -E env
    PRYON_LIB=$<TARGET_FILE:pryon_mock>
    PRYON_MODEL_ROOT=${CMAKE_SOURCE_DIR}/tests/fixtures/models
    PRYON_MOCK_FORCE_DETECT=1
    PRYON_MOCK_REQUIRE_CALLBACKS=1
    ${CMAKE_SOURCE_DIR}/tests/pryon_stream_test.sh $<TARGET_FILE:pryon>)
  add_test(NAME pryon_json_and_list COMMAND ${CMAKE_COMMAND} -E env
    PRYON_LIB=$<TARGET_FILE:pryon_mock>
    PRYON_MODEL_ROOT=${CMAKE_SOURCE_DIR}/tests/fixtures/models
    PRYON_MOCK_FORCE_DETECT=1
    PRYON_MOCK_REQUIRE_CALLBACKS=1
    ${CMAKE_SOURCE_DIR}/tests/pryon_json_test.sh $<TARGET_FILE:pryon> ${CMAKE_SOURCE_DIR}/tests/fixtures/models)
  add_test(NAME pipeline_c_mock COMMAND ${CMAKE_COMMAND} -E env
    AFE=$<TARGET_FILE:afe>
    PRYON=$<TARGET_FILE:pryon>
    ASP_LIB=$<TARGET_FILE:asp_mock>
    PRYON_LIB=$<TARGET_FILE:pryon_mock>
    PRYON_MODEL_ROOT=${CMAKE_SOURCE_DIR}/tests/fixtures/models
    PRYON_MOCK_FORCE_DETECT=1
    ${CMAKE_SOURCE_DIR}/tests/pipeline_example_test.sh $<TARGET_FILE:pipeline-c>)
  add_test(NAME partial_streams COMMAND ${CMAKE_COMMAND} -E env
    ASP_LIB=$<TARGET_FILE:asp_mock>
    PRYON_LIB=$<TARGET_FILE:pryon_mock>
    PRYON_MODEL_ROOT=${CMAKE_SOURCE_DIR}/tests/fixtures/models
    ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tests/partial_stream_test.py
      $<TARGET_FILE:afe> $<TARGET_FILE:pryon> ${CMAKE_SOURCE_DIR}/tests/fixtures/models)
  add_test(NAME afe_conversion COMMAND ${CMAKE_COMMAND} -E env
    ASP_LIB=$<TARGET_FILE:asp_mock>
    ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tests/afe_conversion_test.py $<TARGET_FILE:afe>)
  add_test(NAME pryon_threshold COMMAND ${CMAKE_COMMAND} -E env
    PRYON_LIB=$<TARGET_FILE:pryon_mock>
    ${CMAKE_SOURCE_DIR}/tests/pryon_threshold_test.sh
      $<TARGET_FILE:pryon> ${CMAKE_SOURCE_DIR}/tests/fixtures/models)
  add_test(NAME missing_symbols COMMAND ${CMAKE_SOURCE_DIR}/tests/missing_symbol_test.sh
      $<TARGET_FILE:afe> $<TARGET_FILE:pryon> ${CMAKE_SOURCE_DIR}/tests/fixtures/models)
  add_test(NAME minimal_examples COMMAND ${CMAKE_SOURCE_DIR}/tests/examples_stream_test.sh
    ${CMAKE_BINARY_DIR} ${CMAKE_SOURCE_DIR})
  add_test(NAME firmware_script COMMAND ${CMAKE_SOURCE_DIR}/tests/firmware_script_test.sh)
  add_test(NAME converters COMMAND ${Python3_EXECUTABLE}
    ${CMAKE_SOURCE_DIR}/tests/converters_test.py ${CMAKE_SOURCE_DIR})
  set_tests_properties(pipeline_c_mock PROPERTIES WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
endif()

if(BUILD_TESTING)
  add_custom_target(check
    COMMAND ${CMAKE_CTEST_COMMAND} --output-on-failure
    DEPENDS afe pryon asp_mock pryon_mock pipeline-c
    USES_TERMINAL)
else()
  add_custom_target(check
    COMMAND ${CMAKE_COMMAND} -E echo "check requires -DBUILD_TESTING=ON"
    DEPENDS afe pryon
    USES_TERMINAL)
endif()
