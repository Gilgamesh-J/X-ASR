function(download_kissfft)
  if(CMAKE_VERSION VERSION_LESS 3.11)
    list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_LIST_DIR}/../cmake/Modules)
  endif()

  include(FetchContent)

  # the latest commit as of 2025.05.28
  set(kissfft_URL  "https://github.com/mborgerding/kissfft/archive/febd4caeed32e33ad8b2e0bb5ea77542c40f18ec.zip")
  set(kissfft_URL2 "")
  set(kissfft_HASH "SHA256=497103e664168ebe39580b757adbe616f6cf85a16572af581ca7bc42d0ab13fd")

  # If you don't have access to the Internet,
  # please pre-download kissfft
  set(possible_file_locations
    $ENV{HOME}/Downloads/kissfft-febd4caeed32e33ad8b2e0bb5ea77542c40f18ec.zip
    ${CMAKE_SOURCE_DIR}/kissfft-febd4caeed32e33ad8b2e0bb5ea77542c40f18ec.zip
    ${CMAKE_BINARY_DIR}/kissfft-febd4caeed32e33ad8b2e0bb5ea77542c40f18ec.zip
    /tmp/kissfft-febd4caeed32e33ad8b2e0bb5ea77542c40f18ec.zip
    /star-fj/fangjun/download/github/kissfft-febd4caeed32e33ad8b2e0bb5ea77542c40f18ec.zip
  )

  foreach(f IN LISTS possible_file_locations)
    if(EXISTS ${f})
      set(kissfft_URL  "${f}")
      file(TO_CMAKE_PATH "${kissfft_URL}" kissfft_URL)
      set(kissfft_URL2)
      break()
    endif()
  endforeach()

  set(KISSFFT_PKGCONFIG OFF CACHE BOOL "" FORCE)
  set(KISSFFT_STATIC ON CACHE BOOL "" FORCE)
  set(KISSFFT_TEST OFF CACHE BOOL "" FORCE)
  set(KISSFFT_TOOLS OFF CACHE BOOL "" FORCE)

  FetchContent_Declare(kissfft
    URL
      ${kissfft_URL}
      ${kissfft_URL2}
    URL_HASH          ${kissfft_HASH}
  )

  FetchContent_GetProperties(kissfft)
  if(NOT kissfft_POPULATED)
    message(STATUS "Downloading kissfft from ${kissfft_URL}")
    FetchContent_Populate(kissfft)
  endif()
  message(STATUS "kissfft is downloaded to ${kissfft_SOURCE_DIR}")
  message(STATUS "kissfft's binary dir is ${kissfft_BINARY_DIR}")

  if(BUILD_SHARED_LIBS)
    set(_build_shared_libs_bak ${BUILD_SHARED_LIBS})
    set(BUILD_SHARED_LIBS OFF)
  endif()

  add_subdirectory(${kissfft_SOURCE_DIR} ${kissfft_BINARY_DIR} EXCLUDE_FROM_ALL)

  if(_build_shared_libs_bak)
    set_target_properties(kissfft
      PROPERTIES
        POSITION_INDEPENDENT_CODE ON
        C_VISIBILITY_PRESET hidden
        CXX_VISIBILITY_PRESET hidden
    )
    set(BUILD_SHARED_LIBS ON)
  endif()

  set(kissfft_SOURCE_DIR ${kissfft_SOURCE_DIR} PARENT_SCOPE)

  include_directories(kissfft
      ${kissfft_SOURCE_DIR}
  )

endfunction()

download_kissfft()
