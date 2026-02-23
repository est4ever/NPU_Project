@echo off
cd C:\Users\ser13\NPU_Project
echo Running executable...
dist\npu_wrapper.exe ./models/Qwen2.5-0.5B-Instruct --policy PERFORMANCE
echo Exit code: %ERRORLEVEL%
pause
