

sendsig() { 
  local pspid; 
  pspid=$(pgrep -f "testtitle");  
  if [[ "$pspid" == "" ]]; then   
    echo "error process not found";   
    return 1; 
  else   
    echo "found pid $pspid";   
    kill -s SIGUSR1 $$; 
  fi; return 0;
}
sendsig2() { 
  local pspid; 
  pspid=$(pgrep -f "testtitle");  
  if [[ "$pspid" == "" ]]; then   
    echo "error process not found";   
    return 1; 
  else   
    echo "found pid $pspid";   
    kill -s SIGUSR2 $$; 
  fi; return 0;
}



testrunonsig1(){ 
  echo "ran testrunonsig1";
  echo "ran testrunonsig1" > /tmp/testrunonsig1;
  mkdir -p /home/gp/testrunonsig1;
  return 1
}

testrunonsig2(){ 
  echo "ran testrunonsig2";
  echo "ran testrunonsig2" > /tmp/testrunonsig2;
  mkdir -p /home/gp/testrunonsig2;
  return 1
}

resetsigs(){ 
  rm -rf /tmp/testrunonsig1;
  rm -rf /home/gp/testrunonsig1;
  rm -rf /tmp/testrunonsig2;
  rm -rf /home/gp/testrunonsig2;
  return 1
}

trap testrunonsig1 SIGUSR1
trap testrunonsig2 SIGUSR2

# fails, no xeyes running
sendsig

xeyes -display 192.168.50.1:0.0 -title "testtitle" > /dev/null 2>&1 &

# this sends a SIGUSR2 to the pid of xeyes
sendsig2


# xrunsigusr2 should be ran but is not
