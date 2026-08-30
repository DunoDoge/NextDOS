target_sources(dosboxcommon PRIVATE
  autoexec.cpp
  command_line.cpp
  file_reader.cpp
  shell.cpp
  shell_batch.cpp
  shell_history.cpp
  shell_misc.cpp)

if (DOSBOX_OHOS_EMBED)
  # No host executable; this is engine functionality and stays in the library
  target_sources(dosboxcommon PRIVATE shell_cmds.cpp)
else()
  target_sources(dosbox PRIVATE shell_cmds.cpp)
endif()
