#include <stdio.h>
int MottyAdd(int,int);
int main(void){ int r=MottyAdd(2,3); printf("direct call MottyAdd(2,3)=%d %s\n", r, r==5?"CORRECT":"WRONG"); return r==5?0:1; }
